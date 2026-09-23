// ---------------------------------------------------------------------------
// rv32imc_top.v - 5-stage pipelined RV32IMC CPU (top level)
//
//   IF -> ID -> EX -> MEM -> WB
//
// - RV32I + M + C. C-extension decompressed in ID.
// - Forwarding EX/MEM -> EX and MEM/WB -> EX; load-use stall in ID.
// - Bimodal branch predictor (512x2-bit BHT) + 64-entry BTB in IF;
//   branches/jumps resolve in EX, mispredict => 2-cycle flush.
//   JALR targets tracked through the BTB.
// - Custom read-only perf CSRs: 0x7C0 = branches resolved in EX,
//   0x7C1 = ... of which mispredicted.
// - M-extension: 2-cycle pipelined multiplier, ~35-cycle divider; EX stalls.
// - Machine-mode CSRs: mstatus/mie/mtvec/mscratch/mepc/mcause/mtval/mip,
//   mcycle(h)/minstret(h). ecall/ebreak/illegal-insn trap, mret supported.
//   Precise machine-mode interrupts (MEI > MSI > MTI): taken at an empty
//   pipeline after draining in-flight instructions; mepc = oldest
//   not-yet-retired PC.
// - Memory: separate I/D ports with wait (stall) inputs: imem_wait /
//   dmem_wait. While asserted the pipeline stalls cleanly and the in-flight
//   request is held stable.
//
// Ports are named for testbench / OpenROAD integration.
// Plain Verilog-2001, Yosys compatible.
// ---------------------------------------------------------------------------
`timescale 1ns/1ps

module rv32imc_top (
    input  wire        clk,
    input  wire        rst_n,
    // instruction memory interface (combinational read)
    output wire [31:0] imem_addr,
    input  wire [31:0] imem_rdata,
    input  wire        imem_wait,    // fetch not ready: hold request, stall IF
    // data memory interface
    output wire        dmem_en,
    output wire [31:0] dmem_addr,
    output wire [31:0] dmem_wdata,
    output wire [3:0]  dmem_wstrb,   // byte strobes; 0 = read
    input  wire [31:0] dmem_rdata,
    input  wire        dmem_wait,    // data xfer not done: hold request, stall
    // machine external interrupt pending lines (level)
    input  wire [31:0] mip_in,
    // debug / testbench observation
    output wire [31:0] dbg_pc,       // PC of instruction in WB
    output wire [31:0] dbg_instr,    // instruction word in WB
    output wire        dbg_valid     // high when WB holds a real instruction
);

    // ---------------- ALU op encoding (matches alu.v) ----------------
    localparam A_ADD=4'd0, A_SUB=4'd1, A_SLL=4'd2, A_SRL=4'd3, A_SRA=4'd4,
               A_XOR=4'd5, A_OR =4'd6, A_AND=4'd7, A_SLT=4'd8, A_SLTU=4'd9;

    // ============ pipeline registers (declared up-front) ============
    // IF/ID
    reg        if_id_valid;
    reg [31:0] if_id_pc;
    reg [31:0] if_id_instr;
    reg        if_id_is_compressed;
    reg        if_id_pred_taken;   // IF prediction for this instruction
    reg [31:0] if_id_pred_target;
    // ID/EX
    reg        id_ex_valid;
    reg [31:0] id_ex_pc, id_ex_instr, id_ex_rs1_data, id_ex_rs2_data, id_ex_imm;
    reg        id_ex_pred_taken;   // prediction carried from IF
    reg [31:0] id_ex_pred_target;
    reg [4:0]  id_ex_rs1, id_ex_rs2, id_ex_rd;
    reg [2:0]  id_ex_funct3;
    reg [3:0]  id_ex_alu_op;
    reg [1:0]  id_ex_a_sel;
    reg        id_ex_b_sel;
    reg        id_ex_is_branch, id_ex_is_jal, id_ex_is_jalr;
    reg        id_ex_mem_read, id_ex_mem_write;
    reg [1:0]  id_ex_mem_size;
    reg        id_ex_mem_unsigned;
    reg [1:0]  id_ex_wb_sel;
    reg        id_ex_rd_write;
    reg        id_ex_is_csr;
    reg [1:0]  id_ex_csr_op;
    reg        id_ex_csr_imm;
    reg [11:0] id_ex_csr_addr;
    reg        id_ex_is_mul, id_ex_is_div;
    reg [1:0]  id_ex_muldiv_op;
    reg        id_ex_is_ecall, id_ex_is_ebreak, id_ex_is_mret, id_ex_is_illegal;
    reg        id_ex_is_compressed;
    // EX/MEM
    reg        ex_mem_valid;
    reg [31:0] ex_mem_pc, ex_mem_instr, ex_mem_alu_result, ex_mem_store_data;
    reg [31:0] ex_mem_csr_rdata;
    reg [4:0]  ex_mem_rd;
    reg        ex_mem_mem_read, ex_mem_mem_write;
    reg [1:0]  ex_mem_mem_size;
    reg        ex_mem_mem_unsigned;
    reg [1:0]  ex_mem_wb_sel;
    reg        ex_mem_rd_write;
    reg        ex_mem_is_compressed;
    reg        ex_mem_need_xword; // pre-decoded in EX: crosses 32-bit word boundary
    // MEM/WB
    reg        mem_wb_valid;
    reg [31:0] mem_wb_pc, mem_wb_instr;
    reg [4:0]  mem_wb_rd;
    reg        mem_wb_rd_write;
    reg [31:0] mem_wb_wdata;     // selected writeback data (registered in MEM)
    // misaligned-access second-cycle state
    reg        mem_xword;        // 1: this cycle reads/writes the second word
    reg [31:0] mem_rdata0;       // first word latched during cycle A (loads)
    // cross-section wires (assigned in later sections)
    wire load_use_stall, csr_stall, ex_muldiv_stall, if_flush;
    wire mem_hold; // MEM stage: first cycle of a word-crossing misaligned access
    wire dmem_stall; // dmem_wait asserted while a MEM-stage request is active
    wire pc_hold;    // pc_stall plus the interrupt drain (front-end hold)
    wire [31:0] pc_d; // pc register D input; also predictor lookup address
    wire irq_drain;  // interrupt pending: draining pipe, fetching nothing new
    wire irq_take;   // interrupt taken this cycle (pipe empty)
    wire ex_is_muldiv; // EX holds a mul/div (defined in EX section)
    // branch predictor <-> EX update signals
    wire bht_upd_valid, bht_upd_taken, btb_upd_valid;
    wire [31:0] ex_actual_target;
    wire id_ex_csr_we;
    wire rf_we;
    wire [31:0] wb_data;
    wire [31:0] ex_trap_cause, ex_trap_tval;
    wire csr_we_ex;
    wire [31:0] csr_wdata, csr_rmask;

    // ============================ IF stage ============================
    // 16-bit fetch buffer (skid): handles 32-bit insns split across two
    // 32-bit memory words. pc may sit on either halfword; the length bits
    // are always taken from the halfword AT pc.
    reg [31:0] pc;
    reg [15:0] fbuf;        // latched low-address half of a split insn
    reg [31:0] fbuf_pc;     // pc of the pending split instruction
    reg        fbuf_valid;  // split fetch awaiting second half
    // prediction latched during the setup cycle of a split fetch, so the
    // completion cycle can apply it (pc has already advanced by then)
    reg        fbuf_pred_taken;
    reg [31:0] fbuf_pred_target;

    // ---- branch predictor (IF lookup) ----
    // lookup_pc is the pc register's D input (pc_d, defined below); the
    // predictor registers it as its SRAM read address, so the registered
    // address tracks pc exactly and lookup timing is unchanged.
    wire        pred_btb_hit;
    wire        pred_taken;
    wire [31:0] pred_target;
    branch_pred u_bpred (
        .clk           (clk),
        .rst_n         (rst_n),
        .lookup_pc     (pc_d),
        .btb_hit       (pred_btb_hit),
        .pred_taken    (pred_taken),
        .pred_target   (pred_target),
        .bht_upd_valid (bht_upd_valid),
        .bht_upd_pc    (id_ex_pc),
        .bht_upd_taken (bht_upd_taken),
        .btb_upd_valid (btb_upd_valid),
        .btb_upd_pc    (id_ex_pc),
        .btb_upd_target(ex_actual_target)
    );

    wire [15:0] pc_half      = pc[1] ? imem_rdata[31:16] : imem_rdata[15:0];
    wire        pc_half_is32 = (pc_half[1:0] == 2'b11);
    // pc on odd halfword + 32-bit insn -> second half is in the next word
    wire        need_pending = pc[1] && pc_half_is32 && !fbuf_valid;

    // EX-stage redirect / trap / mret (computed combinationally below)
    wire        ex_redirect, ex_trap, ex_mret;
    wire [31:0] ex_target, trap_vector, mepc_out;

    // dmem_wait stalls the pipeline only while a data-memory request is
    // actually in flight in MEM; a spuriously asserted wait with no request
    // does not stall. While stalled the ex_mem_* registers (and mem_xword)
    // are held, so dmem_en/addr/wdata/wstrb stay stable -- the in-flight
    // request is held, not dropped or re-issued.
    assign dmem_stall = dmem_wait && ex_mem_valid &&
                        (ex_mem_mem_read || ex_mem_mem_write);

    // imem_wait is masked while a mul/div is in flight in EX: the front end
    // is already stalled by ex_muldiv_stall (no fetch is happening), and
    // holding ID/EX on imem_wait would lose the multiplier's 1-cycle valid
    // pulse, forcing a restart that samples stale forwarding. Masking is
    // safe because pc_stall covers ex_muldiv_stall.
    wire imem_wait_eff = imem_wait && !ex_is_muldiv;

    wire pc_stall = load_use_stall || csr_stall || ex_muldiv_stall || mem_hold ||
                    dmem_stall || imem_wait_eff;
    // pc_hold adds the interrupt drain: while draining, the front end holds
    // (fetches nothing new) and in-flight instructions retire.
    assign pc_hold = pc_stall || irq_drain;

    wire [31:0] pc_next = (ex_trap || irq_take) ? trap_vector :
                          ex_mret     ? mepc_out    :
                          ex_redirect ? ex_target   :
                          fbuf_valid  ? (fbuf_pred_taken ? fbuf_pred_target
                                                        : (fbuf_pc + 32'd4)) :
                          need_pending? (pc + 32'd2) :
                          pred_taken  ? pred_target :
                                        (pc + (pc_half_is32 ? 32'd4 : 32'd2));

    // pc D input, also the predictor's registered lookup address.
    assign pc_d = (if_flush || !pc_hold) ? pc_next : pc;

    assign imem_addr = pc;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            pc <= 32'b0;
        else if (if_flush)
            // Redirect/trap/mret: the front end is being flushed, so any
            // stall (e.g. load-use on a wrong-path instruction, or an
            // asserted imem_wait) is moot.
            // The pc MUST take the redirect target this cycle; allowing
            // pc_stall to block it loses the redirect and fetches from a
            // stale pc while IF/ID has been flushed (corrupts the stream).
            pc <= pc_next;
        else if (!pc_hold)
            pc <= pc_next;
    end

    // IF/ID pipeline register
    assign if_flush = ex_trap || ex_mret || ex_redirect || irq_take;

    // Backend hold condition, shared by EX/MEM, MEM/WB and ex_tick for
    // exactly-once semantics. mem_hold / dmem_stall mean an older MEM-stage
    // instruction is still in flight (misaligned 2nd beat / waited D-port
    // request): they win over a flush, the EX instruction is held in ID/EX
    // and re-resolves after. But imem_wait must NOT freeze the backend when
    // if_flush is asserted: the redirecting/trapping/mret instruction in EX
    // has to retire (e.g. JAL writes rd), and the older instruction in
    // EX/MEM has to drain to MEM/WB. Freezing the backend on imem_wait
    // while the frontend flushes drops instructions -- the wait x
    // mispredict corner (SoC 2-wait I-port: a c.jal resolving while
    // imem_wait is up never retires, ra stays 0, the CPU reboots in a loop).
    wire backend_hold = mem_hold || dmem_stall || imem_wait_eff; // BUGGY REVERT

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            if_id_valid         <= 1'b0;
            if_id_pc            <= 32'b0;
            if_id_instr         <= 32'b0;
            if_id_is_compressed <= 1'b0;
            if_id_pred_taken    <= 1'b0;
            if_id_pred_target   <= 32'b0;
            fbuf                <= 16'b0;
            fbuf_pc             <= 32'b0;
            fbuf_valid          <= 1'b0;
            fbuf_pred_taken     <= 1'b0;
            fbuf_pred_target    <= 32'b0;
        end else if (if_flush) begin
            if_id_valid <= 1'b0;
            fbuf_valid  <= 1'b0;
        end else if (irq_drain) begin
            // Interrupt drain: fetch nothing new. If the back end can take
            // the IF/ID instruction this cycle (!pc_stall means ID/EX
            // captures it), mark IF/ID empty; otherwise hold it (ID/EX is
            // stalled or injecting an interlock bubble and still needs it).
            // A pending split fetch (fbuf) is held and discarded on
            // irq_take (via if_flush); irq_mepc accounts for it.
            if (!pc_stall)
                if_id_valid <= 1'b0;
        end else if (!pc_stall) begin
            if (fbuf_valid) begin
                // completion: second half arrived
                if_id_valid         <= 1'b1;
                if_id_pc            <= fbuf_pc;
                if_id_instr         <= {imem_rdata[15:0], fbuf};
                if_id_is_compressed <= 1'b0;
                if_id_pred_taken    <= fbuf_pred_taken;
                if_id_pred_target   <= fbuf_pred_target;
                fbuf_valid          <= 1'b0;
            end else if (need_pending) begin
                // setup: latch first half, insert one bubble.
                // Also latch the prediction made for this pc now: pc
                // advances next cycle, but the prediction must be applied
                // (and carried) for fbuf_pc at completion time.
                if_id_valid    <= 1'b0;
                fbuf           <= pc_half;
                fbuf_pc        <= pc;
                fbuf_valid     <= 1'b1;
                fbuf_pred_taken  <= pred_taken;
                fbuf_pred_target <= pred_target;
            end else begin
                if_id_valid         <= 1'b1;
                if_id_pc            <= pc;
                if_id_instr         <= pc_half_is32 ? imem_rdata : {16'b0, pc_half};
                if_id_is_compressed <= !pc_half_is32;
                if_id_pred_taken    <= pred_taken;
                if_id_pred_target   <= pred_target;
            end
        end
    end

    // ============================ interrupt detection ============================
    // Precise machine-mode interrupts.
    //   pending = ((mip & mie) != 0) for the machine interrupt bits,
    //   priority MEI(11) > MSI(3) > MTI(7); other mip bits are not serviced.
    // When pending && mstatus.MIE && no synchronous trap is present, the
    // pipeline drains (irq_drain: front end holds, in-flight instructions
    // retire normally) and the interrupt is taken exactly when the pipe is
    // empty (irq_take). Then:
    //   - mepc = pc of the oldest not-yet-retired instruction (the next
    //     fetch address; fbuf_pc if a split fetch was pending),
    //   - mcause = 0x80000000 | irq_id,
    //   - nothing retires after the take (the pipe is empty; younger stages
    //     are flushed and the front end redirects to the trap vector),
    //   - MIE is cleared by the CSR trap logic (no nesting).
    // A synchronous trap in EX suppresses the interrupt (sync wins); after
    // any trap MIE=0, so no extra in-flight tracking is needed.
    wire [31:0] mie_bits;
    wire        mstatus_mie;
    wire [31:0] mip_mie = mip_in & mie_bits;
    wire        irq_mei = mip_mie[11];
    wire        irq_msi = mip_mie[3];
    wire        irq_mti = mip_mie[7];
    wire [4:0]  irq_id  = irq_mei ? 5'd11 :
                          irq_msi ? 5'd3  : 5'd7;
    wire        irq_pending = irq_mei || irq_msi || irq_mti;
    wire        pipe_empty  = !if_id_valid && !id_ex_valid &&
                              !ex_mem_valid && !mem_wb_valid;
    wire        irq_armed = irq_pending && mstatus_mie && !ex_trap;
    assign      irq_drain = irq_armed && !pipe_empty;
    assign      irq_take  = irq_armed && pipe_empty;
    wire [31:0] irq_mepc = fbuf_valid ? fbuf_pc : pc;

    // ============================ ID stage ============================
    // Decompress if 16-bit
    wire [31:0] dec_instr;
    wire        dec_illegal;
    compressed_decoder u_cdec (
        .cin     (if_id_instr[15:0]),
        .cout    (dec_instr),
        .illegal (dec_illegal)
    );
    wire [31:0] instr = (if_id_instr[1:0] == 2'b11) ? if_id_instr : dec_instr;

    wire [6:0] opcode   = instr[6:0];
    wire [4:0] id_rd    = instr[11:7];
    wire [4:0] id_rs1   = instr[19:15];
    wire [4:0] id_rs2   = instr[24:20];
    wire [2:0] id_funct3= instr[14:12];
    wire [6:0] id_funct7= instr[31:25];

    wire [31:0] imm_i = {{20{instr[31]}}, instr[31:20]};
    wire [31:0] imm_s = {{20{instr[31]}}, instr[31:25], instr[11:7]};
    wire [31:0] imm_b = {{19{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0};
    wire [31:0] imm_u = {instr[31:12], 12'b0};
    wire [31:0] imm_j = {{11{instr[31]}}, instr[31], instr[19:12], instr[20], instr[30:21], 1'b0};

    // ---- ID combinational decode ----
    reg [3:0]  id_alu_op;
    reg [1:0]  id_a_sel;        // 00 rs1, 01 pc, 10 zero
    reg        id_b_sel;        // 0 rs2, 1 imm
    reg [31:0] id_imm;
    reg        id_is_branch, id_is_jal, id_is_jalr;
    reg        id_mem_read, id_mem_write;
    reg [1:0]  id_mem_size;     // 00 byte, 01 half, 10 word
    reg        id_mem_unsigned;
    reg [1:0]  id_wb_sel;       // 00 alu, 01 mem, 10 pc+4, 11 csr
    reg        id_rd_write;
    reg        id_is_csr;
    reg [1:0]  id_csr_op;       // 01 RW, 10 RS, 11 RC
    reg        id_csr_imm;
    reg [11:0] id_csr_addr;
    reg        id_is_mul, id_is_div;
    reg [1:0]  id_muldiv_op;
    reg        id_is_ecall, id_is_ebreak, id_is_mret;
    reg        id_illegal;
    reg        id_uses_rs1, id_uses_rs2;

    always @(*) begin
        // defaults: NOP
        id_alu_op = A_ADD; id_a_sel = 2'b00; id_b_sel = 1'b0; id_imm = 32'b0;
        id_is_branch = 1'b0; id_is_jal = 1'b0; id_is_jalr = 1'b0;
        id_mem_read = 1'b0; id_mem_write = 1'b0;
        id_mem_size = 2'b10; id_mem_unsigned = 1'b0;
        id_wb_sel = 2'b00; id_rd_write = 1'b0;
        id_is_csr = 1'b0; id_csr_op = 2'b00; id_csr_imm = 1'b0; id_csr_addr = 12'b0;
        id_is_mul = 1'b0; id_is_div = 1'b0; id_muldiv_op = 2'b00;
        id_is_ecall = 1'b0; id_is_ebreak = 1'b0; id_is_mret = 1'b0;
        id_illegal = dec_illegal && (if_id_instr[1:0] != 2'b11);
        id_uses_rs1 = 1'b0; id_uses_rs2 = 1'b0;

        if (if_id_valid && !id_illegal) begin
            case (opcode)
                7'b0110011: begin // OP
                    if (id_funct7 == 7'b0000001) begin // M extension
                        id_rd_write = 1'b1;
                        id_uses_rs1 = 1'b1; id_uses_rs2 = 1'b1;
                        id_muldiv_op = id_funct3[1:0];
                        if (id_funct3[2] == 1'b0)
                            id_is_mul = 1'b1;
                        else
                            id_is_div = 1'b1;
                    end else begin
                        id_rd_write = 1'b1;
                        id_uses_rs1 = 1'b1; id_uses_rs2 = 1'b1;
                        case (id_funct3)
                            3'b000: id_alu_op = (id_funct7 == 7'b0100000) ? A_SUB : A_ADD;
                            3'b001: id_alu_op = A_SLL;
                            3'b010: id_alu_op = A_SLT;
                            3'b011: id_alu_op = A_SLTU;
                            3'b100: id_alu_op = A_XOR;
                            3'b101: id_alu_op = (id_funct7 == 7'b0100000) ? A_SRA : A_SRL;
                            3'b110: id_alu_op = A_OR;
                            3'b111: id_alu_op = A_AND;
                        endcase
                        if (id_funct7 != 7'b0000000 && id_funct7 != 7'b0100000 && id_funct7 != 7'b0000001)
                            id_illegal = 1'b1;
                    end
                end
                7'b0010011: begin // OP-IMM
                    id_rd_write = 1'b1;
                    id_uses_rs1 = 1'b1;
                    id_b_sel = 1'b1;
                    id_imm = imm_i;
                    case (id_funct3)
                        3'b000: id_alu_op = A_ADD;
                        3'b001: begin
                            id_alu_op = A_SLL;
                            if (id_funct7 != 7'b0000000) id_illegal = 1'b1;
                        end
                        3'b010: id_alu_op = A_SLT;
                        3'b011: id_alu_op = A_SLTU;
                        3'b100: id_alu_op = A_XOR;
                        3'b101: begin
                            id_alu_op = (instr[30] == 1'b0) ? A_SRL : A_SRA;
                            if (id_funct7 != 7'b0000000 && id_funct7 != 7'b0100000)
                                id_illegal = 1'b1;
                        end
                        3'b110: id_alu_op = A_OR;
                        3'b111: id_alu_op = A_AND;
                    endcase
                end
                7'b0000011: begin // LOAD
                    id_rd_write = 1'b1;
                    id_uses_rs1 = 1'b1;
                    id_b_sel = 1'b1;
                    id_imm = imm_i;
                    id_mem_read = 1'b1;
                    id_wb_sel = 2'b01;
                    case (id_funct3)
                        3'b000: begin id_mem_size = 2'b00; id_mem_unsigned = 1'b0; end
                        3'b001: begin id_mem_size = 2'b01; id_mem_unsigned = 1'b0; end
                        3'b010: begin id_mem_size = 2'b10; end
                        3'b100: begin id_mem_size = 2'b00; id_mem_unsigned = 1'b1; end
                        3'b101: begin id_mem_size = 2'b01; id_mem_unsigned = 1'b1; end
                        default: id_illegal = 1'b1;
                    endcase
                end
                7'b0100011: begin // STORE
                    id_uses_rs1 = 1'b1; id_uses_rs2 = 1'b1;
                    id_b_sel = 1'b1;
                    id_imm = imm_s;
                    id_mem_write = 1'b1;
                    case (id_funct3)
                        3'b000: id_mem_size = 2'b00;
                        3'b001: id_mem_size = 2'b01;
                        3'b010: id_mem_size = 2'b10;
                        default: id_illegal = 1'b1;
                    endcase
                end
                7'b1100011: begin // BRANCH
                    id_is_branch = 1'b1;
                    id_uses_rs1 = 1'b1; id_uses_rs2 = 1'b1;
                    id_imm = imm_b;
                    case (id_funct3)
                        3'b000, 3'b001: id_alu_op = A_SUB;
                        3'b100, 3'b101: id_alu_op = A_SLT;
                        3'b110, 3'b111: id_alu_op = A_SLTU;
                        default: id_illegal = 1'b1;
                    endcase
                end
                7'b1101111: begin // JAL
                    id_is_jal = 1'b1;
                    id_imm = imm_j;
                    id_rd_write = 1'b1;
                    id_wb_sel = 2'b10;
                end
                7'b1100111: begin // JALR
                    id_is_jalr = 1'b1;
                    id_uses_rs1 = 1'b1;
                    id_b_sel = 1'b1;
                    id_imm = imm_i;
                    id_rd_write = 1'b1;
                    id_wb_sel = 2'b10;
                    if (id_funct3 != 3'b000) id_illegal = 1'b1;
                end
                7'b0110111: begin // LUI
                    id_rd_write = 1'b1;
                    id_a_sel = 2'b10;
                    id_b_sel = 1'b1;
                    id_imm = imm_u;
                end
                7'b0010111: begin // AUIPC
                    id_rd_write = 1'b1;
                    id_a_sel = 2'b01;
                    id_b_sel = 1'b1;
                    id_imm = imm_u;
                end
                7'b1110011: begin // SYSTEM
                    case (id_funct3)
                        3'b000: begin // PRIV
                            if (instr[31:20] == 12'b0)
                                id_is_ecall = 1'b1;
                            else if (instr[31:20] == 12'b1)
                                id_is_ebreak = 1'b1;
                            else if (instr == 32'h30200073)
                                id_is_mret = 1'b1;
                            else
                                id_illegal = 1'b1;
                        end
                        3'b001, 3'b010, 3'b011,
                        3'b101, 3'b110, 3'b111: begin
                            id_is_csr = 1'b1;
                            if (!id_funct3[2])
                                id_uses_rs1 = 1'b1; // register forms use rs1
                            id_csr_op = {1'b0, id_funct3[1]} == 2'b0 ? 2'b01 :
                                        (id_funct3[1:0] == 2'b10) ? 2'b10 : 2'b11;
                            // funct3: 001/101 -> RW(01), 010/110 -> RS(10), 011/111 -> RC(11)
                            id_csr_imm = id_funct3[2];
                            id_csr_addr = instr[31:20];
                            id_rd_write = 1'b1;
                            id_wb_sel = 2'b11;
                            if (id_csr_imm)
                                id_imm = {27'b0, id_rs1};
                        end
                        default: id_illegal = 1'b1;
                    endcase
                end
                7'b0001111: begin // FENCE / FENCE.I -> NOP
                end
                default: id_illegal = 1'b1;
            endcase
        end
    end

    // register file
    wire [31:0] rf_rdata1, rf_rdata2;
    regfile u_rf (
        .clk    (clk),
        .we     (rf_we),
        .waddr  (mem_wb_rd),
        .wdata  (wb_data),
        .raddr1 (id_rs1),
        .raddr2 (id_rs2),
        .rdata1 (rf_rdata1),
        .rdata2 (rf_rdata2)
    );

    // ---- hazard detection ----
    wire id_csr_mret = (id_is_csr || id_is_mret) && if_id_valid;
    assign load_use_stall = if_id_valid && id_ex_valid && id_ex_mem_read &&
                          (id_ex_rd != 5'b0) &&
                          ((id_uses_rs1 && (id_ex_rd == id_rs1)) ||
                           (id_uses_rs2 && (id_ex_rd == id_rs2)));
    assign csr_stall = id_csr_mret && id_ex_valid && id_ex_csr_we;

    // ID/EX pipeline register
    // id_ex_csr_we: this EX stage will write a CSR (for csr_stall of next instr)
    assign id_ex_csr_we = id_ex_valid && id_ex_is_csr && (id_ex_csr_op != 2'b00);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            id_ex_valid <= 1'b0;
            id_ex_pred_taken <= 1'b0;
            id_ex_pred_target <= 32'b0;
        end else if (mem_hold) begin
            // hold: MEM is doing the 2nd cycle of a misaligned access;
            // the older MEM instruction must complete first (wins over flush)
        end else if (if_flush) begin
            id_ex_valid <= 1'b0;
            id_ex_pred_taken <= 1'b0;
        end else if (dmem_stall || imem_wait_eff) begin
            // hold: the back end is busy (dmem_wait) or the fetch data is
            // invalid (imem_wait). The ID/EX instruction is valid and must
            // be KEPT -- do not inject a bubble (that would lose it) and do
            // not let a stale flush target it after the flush is gone.
            // (if_flush above still wins while it is asserted.)
        end else if (ex_muldiv_stall) begin
            // hold: mul/div instruction stays in EX
        end else if (load_use_stall || csr_stall) begin
            id_ex_valid <= 1'b0; // inject bubble
            id_ex_pred_taken <= 1'b0;
        end else begin
            id_ex_valid        <= if_id_valid;
            id_ex_pc           <= if_id_pc;
            id_ex_instr        <= instr;
            id_ex_rs1_data     <= rf_rdata1;
            id_ex_rs2_data     <= rf_rdata2;
            id_ex_imm          <= id_imm;
            id_ex_rs1          <= id_rs1;
            id_ex_rs2          <= id_rs2;
            id_ex_rd           <= id_rd;
            id_ex_funct3       <= id_funct3;
            id_ex_alu_op       <= id_alu_op;
            id_ex_a_sel        <= id_a_sel;
            id_ex_b_sel        <= id_b_sel;
            id_ex_is_branch    <= id_is_branch;
            id_ex_is_jal       <= id_is_jal;
            id_ex_is_jalr      <= id_is_jalr;
            id_ex_mem_read     <= id_mem_read;
            id_ex_mem_write    <= id_mem_write;
            id_ex_mem_size     <= id_mem_size;
            id_ex_mem_unsigned <= id_mem_unsigned;
            id_ex_wb_sel       <= id_wb_sel;
            id_ex_rd_write     <= id_rd_write;
            id_ex_is_csr       <= id_is_csr;
            id_ex_csr_op       <= id_csr_op;
            id_ex_csr_imm      <= id_csr_imm;
            id_ex_csr_addr     <= id_csr_addr;
            id_ex_is_mul       <= id_is_mul;
            id_ex_is_div       <= id_is_div;
            id_ex_muldiv_op    <= id_muldiv_op;
            id_ex_is_ecall     <= id_is_ecall;
            id_ex_is_ebreak    <= id_is_ebreak;
            id_ex_is_mret      <= id_is_mret;
            id_ex_is_illegal   <= id_illegal;
            id_ex_is_compressed <= if_id_is_compressed;
            id_ex_pred_taken   <= if_id_pred_taken;
            id_ex_pred_target  <= if_id_pred_target;
        end
    end

    // ============================ EX stage ============================
    // forwarding muxes: use the true writeback data (not just alu_result),
    // so JAL(R) (pc+2/4) and CSR instructions forward correctly
    wire [31:0] ex_mem_link_addr = ex_mem_pc + (ex_mem_is_compressed ? 32'd2 : 32'd4);
    wire [31:0] ex_mem_fwd_data = (ex_mem_wb_sel == 2'b10) ? ex_mem_link_addr :
                                  (ex_mem_wb_sel == 2'b11) ? ex_mem_csr_rdata :
                                                             ex_mem_alu_result;
    wire exmem_fwd_rs1 = ex_mem_valid && ex_mem_rd_write && !ex_mem_mem_read &&
                         (ex_mem_rd != 5'b0) && (ex_mem_rd == id_ex_rs1);
    wire exmem_fwd_rs2 = ex_mem_valid && ex_mem_rd_write && !ex_mem_mem_read &&
                         (ex_mem_rd != 5'b0) && (ex_mem_rd == id_ex_rs2);
    wire memwb_fwd_rs1 = mem_wb_valid && mem_wb_rd_write &&
                         (mem_wb_rd != 5'b0) && (mem_wb_rd == id_ex_rs1);
    wire memwb_fwd_rs2 = mem_wb_valid && mem_wb_rd_write &&
                         (mem_wb_rd != 5'b0) && (mem_wb_rd == id_ex_rs2);

    wire [31:0] fwd_rs1 = exmem_fwd_rs1 ? ex_mem_fwd_data :
                          memwb_fwd_rs1 ? wb_data : id_ex_rs1_data;
    wire [31:0] fwd_rs2 = exmem_fwd_rs2 ? ex_mem_fwd_data :
                          memwb_fwd_rs2 ? wb_data : id_ex_rs2_data;

    wire [31:0] alu_a = (id_ex_a_sel == 2'b01) ? id_ex_pc :
                        (id_ex_a_sel == 2'b10) ? 32'b0 : fwd_rs1;
    wire [31:0] alu_b = id_ex_b_sel ? id_ex_imm : fwd_rs2;

    wire [31:0] alu_result;
    wire        alu_zero;
    alu u_alu (
        .a      (alu_a),
        .b      (alu_b),
        .alu_op (id_ex_alu_op),
        .result (alu_result),
        .zero   (alu_zero)
    );

    // branch / jump resolution vs. the IF-stage prediction
    wire [31:0] br_target = id_ex_pc + id_ex_imm;
    wire        br_taken_raw =
        (id_ex_funct3 == 3'b000) ? alu_zero :
        (id_ex_funct3 == 3'b001) ? ~alu_zero :
        (id_ex_funct3 == 3'b100) ? alu_result[0] :
        (id_ex_funct3 == 3'b101) ? ~alu_result[0] :
        (id_ex_funct3 == 3'b110) ? alu_result[0] :
        (id_ex_funct3 == 3'b111) ? ~alu_result[0] : 1'b0;

    wire ex_br_taken = id_ex_valid && id_ex_is_branch && br_taken_raw;
    wire ex_jump     = id_ex_valid && (id_ex_is_jal || id_ex_is_jalr);
    wire ex_is_cf    = id_ex_valid &&
                       (id_ex_is_branch || id_ex_is_jal || id_ex_is_jalr);
    wire ex_actual_taken  = ex_br_taken || ex_jump;  // jal/jalr always taken
    wire [31:0] ex_fallthrough =
        id_ex_pc + (id_ex_is_compressed ? 32'd2 : 32'd4);
    assign ex_actual_target =
        id_ex_is_jalr ? {alu_result[31:1], 1'b0} :
        (id_ex_is_branch && !br_taken_raw) ? ex_fallthrough :
        br_target;

    // Mispredict cases (all flushed through the existing redirect path):
    //  1. control-flow insn: actual direction != predicted direction
    //  2. taken control-flow insn: actual target != predicted target
    //     (JALR target change; BTB halfword-aliasing on 16-bit branches)
    //  3. non-control-flow insn predicted taken (BTB aliasing false
    //     positive: a 16-bit insn at the odd halfword of a word whose even
    //     halfword holds a taken branch). Redirect to fall-through; the
    //     instruction itself still retires normally.
    wire ex_misp_raw = id_ex_valid &&
        ((ex_is_cf && (ex_actual_taken != id_ex_pred_taken)) ||
         (ex_is_cf && ex_actual_taken &&
          (ex_actual_target != id_ex_pred_target)) ||
         (!ex_is_cf && id_ex_pred_taken));
    // Do not redirect while a mul/div is stalled in EX: it must complete
    // and retire (a falsely-predicted 32-bit mul at an odd halfword can
    // alias a 16-bit branch's BTB entry). The redirect fires, exactly once,
    // when the instruction leaves EX.
    wire ex_mispredict = ex_misp_raw && !ex_muldiv_stall;
    assign ex_redirect = ex_mispredict;
    assign ex_target = ex_is_cf ? ex_actual_target : ex_fallthrough;

    // ---- predictor training + performance ticks ----
    // Exactly-once tick for the instruction leaving EX: fires exactly when
    // EX/MEM captures it (mirrors the capture condition via ex_mem_hold).
    // Suppressed while the instruction is held in EX by mem_hold /
    // dmem_stall / imem_wait / muldiv stall; fires (once) when it actually
    // moves to EX/MEM -- including on a flush, so a mispredict resolving
    // during imem_wait still trains the predictor (no permanent
    // mispredict livelock).
    wire ex_tick = id_ex_valid && !ex_muldiv_stall && !mem_hold &&
                   !dmem_stall && !imem_wait_eff; // BUGGY REVERT
    // BHT: train on every resolving control-flow insn toward the actual
    // outcome; also train toward not-taken on a false-positive prediction.
    assign bht_upd_valid = ex_tick && (ex_is_cf || id_ex_pred_taken);
    assign bht_upd_taken = ex_actual_taken;
    // BTB: allocate/overwrite only on taken control-flow insns.
    assign btb_upd_valid = ex_tick && ex_is_cf && ex_actual_taken;

    // CSR perf ticks (custom read-only CSRs 0x7C0 / 0x7C1).
    wire csr_branch_tick     = ex_tick && ex_is_cf;
    wire csr_mispredict_tick = ex_tick && ex_misp_raw;

    // ---- M-extension ----
    assign ex_is_muldiv = id_ex_valid && (id_ex_is_mul || id_ex_is_div);

    reg  ex_muldiv_started;
    wire mul_valid, div_valid;
    wire [31:0] mul_result, div_result;
    wire mul_busy, div_busy;

    wire muldiv_result_valid = (id_ex_is_mul && mul_valid) || (id_ex_is_div && div_valid);
    wire [31:0] muldiv_result = id_ex_is_mul ? mul_result : div_result;
    assign ex_muldiv_stall = ex_is_muldiv && !muldiv_result_valid;

    wire muldiv_flush = if_flush;

    multiplier u_mul (
        .clk   (clk),
        .rst_n (rst_n),
        .start (ex_is_muldiv && id_ex_is_mul && !ex_muldiv_started),
        .a     (fwd_rs1),
        .b     (fwd_rs2),
        .op    (id_ex_muldiv_op),
        .flush (muldiv_flush),
        .busy  (mul_busy),
        .valid (mul_valid),
        .result(mul_result)
    );

    divider u_div (
        .clk     (clk),
        .rst_n   (rst_n),
        .start   (ex_is_muldiv && id_ex_is_div && !ex_muldiv_started),
        .dividend(fwd_rs1),
        .divisor (fwd_rs2),
        .op      (id_ex_muldiv_op),
        .flush   (muldiv_flush),
        .busy    (div_busy),
        .valid   (div_valid),
        .result  (div_result)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            ex_muldiv_started <= 1'b0;
        else if (muldiv_flush || !id_ex_valid)
            ex_muldiv_started <= 1'b0;
        else if (ex_is_muldiv && !ex_muldiv_started)
            ex_muldiv_started <= 1'b1;
        else if (muldiv_result_valid)
            ex_muldiv_started <= 1'b0;
    end

    wire [31:0] ex_result = ex_is_muldiv ? muldiv_result : alu_result;

    // Misalignment pre-decode (timing): decide in EX whether the memory op
    // in ID/EX crosses a 32-bit word boundary. Registered into EX/MEM, so
    // the MEM-stage mem_hold does not combinationally decode
    // ex_mem_alu_result[1:0] (which fed back into EX/MEM clock-enables).
    // Note: ex_result is the address for loads/stores (ex_is_muldiv=0 then).
    wire need_xword_d =
        id_ex_valid && (id_ex_mem_read || id_ex_mem_write) &&
        ((id_ex_mem_size == 2'b10 && ex_result[1:0] != 2'b00) ||
         (id_ex_mem_size == 2'b01 && ex_result[1:0] == 2'b11));

    // ---- CSR access (in EX) ----
    wire [31:0] csr_rdata;
    csr u_csr (
        .clk         (clk),
        .rst_n       (rst_n),
        .addr        (id_ex_csr_addr),
        .we          (csr_we_ex),
        .wdata       (csr_wdata),
        .rdata       (csr_rdata),
        .retire_valid(mem_wb_valid),
        .branch_tick (csr_branch_tick),
        .mispredict_tick(csr_mispredict_tick),
        .trap_valid  (ex_trap || irq_take),
        .trap_cause  (ex_trap ? ex_trap_cause : (32'h80000000 | {27'b0, irq_id})),
        .trap_pc     (ex_trap ? id_ex_pc : irq_mepc),
        .trap_tval   (ex_trap ? ex_trap_tval : 32'b0),
        .trap_vector (trap_vector),
        .mret_valid  (ex_mret),
        .mepc_out    (mepc_out),
        .mip_in      (mip_in),
        .mie_out     (mstatus_mie),
        .mie_bits    (mie_bits)
    );

    assign csr_rmask = id_ex_csr_imm ? id_ex_imm : fwd_rs1;
    assign csr_wdata =
        (id_ex_csr_op == 2'b01) ? csr_rmask :
        (id_ex_csr_op == 2'b10) ? (csr_rdata | csr_rmask) :
        (id_ex_csr_op == 2'b11) ? (csr_rdata & ~csr_rmask) : 32'b0;
    assign csr_we_ex = id_ex_valid && id_ex_is_csr && (id_ex_csr_op != 2'b00) &&
                     ((id_ex_csr_op == 2'b01) || (csr_rmask != 32'b0));

    // ---- traps / mret ----
    assign ex_trap = id_ex_valid &&
                     (id_ex_is_illegal || id_ex_is_ecall || id_ex_is_ebreak);
    assign ex_trap_cause = id_ex_is_illegal ? 32'd2 :
                                id_ex_is_ecall   ? 32'd11 : 32'd3;
    assign ex_trap_tval  = id_ex_is_illegal ? id_ex_instr : 32'b0;
    assign ex_mret = id_ex_valid && id_ex_is_mret;

    // EX/MEM pipeline register
    // EX/MEM: normal capture. NOTE: no if_flush here -- the redirecting
    // instruction itself (branch/jump in EX) must retire, e.g. JAL writes rd.
    // (Trap faulting instructions flow through harmlessly: no rd write.)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ex_mem_valid <= 1'b0;
            ex_mem_need_xword <= 1'b0;
        end else if (backend_hold) begin
            // hold: keep the misaligned access / waited request / stalled
            // fetch in EX/MEM (its dmem_* outputs stay stable). The whole
            // pipeline freezes coherently: ID/EX, EX/MEM and MEM/WB all
            // hold, so no instruction is re-captured (duplicate retire).
            // (imem_wait alone does not hold when if_flush is asserted --
            // see backend_hold -- so the redirecting instruction retires
            // instead of being dropped.)
        end else if (ex_muldiv_stall) begin
            ex_mem_valid <= 1'b0;
            ex_mem_need_xword <= 1'b0;
        end else begin
            ex_mem_valid        <= id_ex_valid;
            ex_mem_pc           <= id_ex_pc;
            ex_mem_instr        <= id_ex_instr;
            ex_mem_alu_result   <= ex_result;
            ex_mem_store_data   <= fwd_rs2;
            ex_mem_csr_rdata    <= csr_rdata;
            ex_mem_rd           <= id_ex_rd;
            ex_mem_mem_read     <= id_ex_mem_read;
            ex_mem_mem_write    <= id_ex_mem_write;
            ex_mem_mem_size     <= id_ex_mem_size;
            ex_mem_mem_unsigned <= id_ex_mem_unsigned;
            ex_mem_wb_sel       <= id_ex_wb_sel;
            ex_mem_rd_write     <= id_ex_rd_write;
            ex_mem_is_compressed <= id_ex_is_compressed;
            ex_mem_need_xword   <= need_xword_d;
        end
    end

    // ============================ MEM stage ============================
    // Misaligned support: an access crossing a 32-bit word boundary takes two
    // cycles. Cycle A touches word0 = {addr[31:2],2'b0} (latching rdata for
    // loads); cycle B (mem_xword=1) touches word0+4 and completes. Only
    // word-size (bsel!=0) and halfword-size (bsel==3) accesses can cross;
    // byte accesses and within-word halfwords are single-cycle.
    // (need_xword is pre-decoded in EX and registered; no combinational
    // decode of ex_mem_alu_result[1:0] here, to keep mem_hold off the
    // critical path.)
    wire [1:0] mem_bsel = ex_mem_alu_result[1:0];
    wire mem_need_xword = ex_mem_valid && ex_mem_need_xword;
    assign mem_hold = mem_need_xword && !mem_xword;  // cycle A: freeze front-end

    wire [31:0] mem_word0_addr = {ex_mem_alu_result[31:2], 2'b00};
    assign dmem_en   = ex_mem_valid && (ex_mem_mem_read || ex_mem_mem_write);
    assign dmem_addr = mem_xword ? (mem_word0_addr + 32'd4) : mem_word0_addr;

    // store byte lanes: word0 gets bytes [bsel .. bsel+nbytes-1]∩[0..3],
    // word1 (cycle B) gets the spill-over bytes
    wire [2:0] mem_nbytes = (ex_mem_mem_size == 2'b10) ? 3'd4 :
                            (ex_mem_mem_size == 2'b01) ? 3'd2 : 3'd1;
    wire [2:0] mem_end    = {1'b0, mem_bsel} + mem_nbytes;   // bsel+nbytes: 1..8
    wire [3:0] mem_strb0  = (4'b1111 << mem_bsel) &
                            (mem_end >= 3'd4 ? 4'b1111 : ~(4'b1111 << mem_end));
    wire [3:0] mem_strb1  = (mem_end > 3'd4) ? ~(4'b1111 << (mem_end - 3'd4))
                                             : 4'b0000;
    assign dmem_wstrb = !ex_mem_valid || !ex_mem_mem_write ? 4'b0000 :
                        mem_xword ? mem_strb1 : mem_strb0;
    // cycle A: data << bsel*8; cycle B: remaining high bytes >> (32-bsel*8)
    assign dmem_wdata = mem_xword ? (ex_mem_store_data >> (6'd32 - {mem_bsel, 3'b0}))
                                  : (ex_mem_store_data << {mem_bsel, 3'b0});

    // load data alignment / sign extension; cycle B merges {word1, word0}
    wire [63:0] mem_r64 = mem_xword ? ({dmem_rdata, mem_rdata0} >> {mem_bsel, 3'b0})
                                    : {32'b0, dmem_rdata >> {mem_bsel, 3'b0}};
    wire [31:0] mem_load_data =
        (ex_mem_mem_size == 2'b10) ? mem_r64[31:0] :
        (ex_mem_mem_size == 2'b01) ?
            (ex_mem_mem_unsigned ? {16'b0, mem_r64[15:0]}
                                 : {{16{mem_r64[15]}}, mem_r64[15:0]}) :
            (ex_mem_mem_unsigned ? {24'b0, mem_r64[7:0]}
                                 : {{24{mem_r64[7]}}, mem_r64[7:0]});

    // misaligned second-cycle state
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mem_xword <= 1'b0;
            mem_rdata0 <= 32'b0;
        end else if (dmem_stall || imem_wait_eff) begin
            // hold: the waited request is still in flight, or the whole
            // pipeline is frozen for imem_wait; do not latch dmem_rdata
            // (invalid) and do not advance mem_xword
        end else if (mem_hold) begin
            mem_xword <= 1'b1;
            mem_rdata0 <= dmem_rdata;   // latch word0 (cycle A)
        end else begin
            mem_xword <= 1'b0;
        end
    end

    // WB write data: selected in MEM (not in WB) so the WB->EX/ID paths
    // start at a register Q, not at a wb_sel->mux combinational cone.
    wire [31:0] mem_wdata_sel =
        (ex_mem_wb_sel == 2'b01) ? mem_load_data :
        (ex_mem_wb_sel == 2'b10) ? ex_mem_link_addr :
        (ex_mem_wb_sel == 2'b11) ? ex_mem_csr_rdata :
                                   ex_mem_alu_result;

    // MEM/WB pipeline register
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mem_wb_valid <= 1'b0;
        end else if (backend_hold) begin
            // hold: don't latch the partial first-cycle data / waited data;
            // the pipeline is frozen coherently (no duplicate retire).
            // (imem_wait alone does not hold when if_flush is asserted --
            // see backend_hold -- so the backend drains and the older
            // instruction is not lost when the frontend flushes.)
        end else begin
            mem_wb_valid      <= ex_mem_valid;
            mem_wb_pc         <= ex_mem_pc;
            mem_wb_instr      <= ex_mem_instr;
            mem_wb_rd         <= ex_mem_rd;
            mem_wb_rd_write   <= ex_mem_rd_write;
            mem_wb_wdata      <= mem_wdata_sel;
        end
    end

    // ============================ WB stage ============================
    // WB stage: writeback data arrives registered from MEM (timing fix:
    // no wb_sel->mux combinational cone here; WB->EX/ID start at a flop Q)
    assign wb_data = mem_wb_wdata;

    assign rf_we = mem_wb_valid && mem_wb_rd_write;

    assign dbg_pc    = mem_wb_pc;
    assign dbg_instr = mem_wb_instr;
    assign dbg_valid = mem_wb_valid;

endmodule
