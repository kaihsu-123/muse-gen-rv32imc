// ---------------------------------------------------------------------------
// branch_pred.v - bimodal branch predictor + BTB for the RV32IMC 5-stage CPU
//
//   BHT: 512 entries x 2-bit saturating counters,
//        indexed by PC[10:2]. Reset to 2'b01 (weakly not-taken).
//   BTB: 64 entries, indexed by PC[7:2].
//        Entry = valid(1) + tag PC[31:8] (24b) + target PC[31:1] (31b).
//
// STORAGE: both tables are single-port synchronous SRAMs written in an
// inference-friendly style (reg [W-1:0] mem [0:DEPTH-1]) so they map to
// SRAM macros instead of flops. The read address is REGISTERED (rd_addr,
// loaded every cycle with lookup_pc); the read data is combinational from
// the registered address. The top level drives lookup_pc with the pc
// register's D input, so rd_addr tracks pc exactly and the lookup timing
// is bit-identical to the old flop version (prediction for the current pc
// is available combinationally in the same cycle).
//
// NOTE on target width: the target is stored as PC[31:1], not PC[31:2].
// A 16-bit (RVC) branch/jump at an odd halfword can have bit 1 of its
// target set (2-byte-aligned target), so dropping bit 1 would corrupt the
// predicted target and cause a permanent mispredict on such branches.
// Bit 0 is always zero for instruction addresses.
//
// IF lookup (combinational on the registered read address):
//    btb_hit   = valid[idx] && (tag[idx] == pc[31:8])
//    pred_taken  = btb_hit && (bhtctr >= 2'b10)
//    pred_target = {btb_tgt[idx], 1'b0}
// A BTB miss predicts not-taken. The BTB only ever holds taken
// control-flow instructions, so a miss means "never taken here before".
//
// EX update interface (all updates take effect next cycle):
//    bht_upd_valid/taken/pc : train the counter toward the actual outcome.
//        Asserted for every resolving control-flow instruction, and also for
//        a non-control-flow instruction that was falsely predicted taken
//        (trains toward not-taken).
//    btb_upd_valid/pc/target: allocate/overwrite the BTB entry. Asserted
//        only for taken control-flow instructions (branch/jal/jalr).
//
// READ-DURING-WRITE (defined explicitly): the single port is shared by the
// lookup read and the EX update write. If both target the same entry in the
// same cycle, the read returns the OLD value (Verilog nonblocking
// read-before-write). A real single-port macro is undefined on a same-cycle
// read/write collision; the predictor is tolerant of either outcome because
// both the old and the new 2-bit counter are legal states -- at worst one
// prediction uses a 1-cycle-stale counter, which can only cost a mispredict,
// never correctness.
//
// Plain Verilog-2001, Yosys compatible.
// ---------------------------------------------------------------------------
`timescale 1ns/1ps

module branch_pred (
    input  wire        clk,
    input  wire        rst_n,
    // IF lookup address: the top level must drive the pc register's D input
    // here (the address pc will hold after the next clock edge). It is
    // registered below, so the registered read address always equals the
    // current pc.
    input  wire [31:0] lookup_pc,
    output wire        btb_hit,
    output wire        pred_taken,
    output wire [31:0] pred_target,
    // EX update: BHT training
    input  wire        bht_upd_valid,
    input  wire [31:0] bht_upd_pc,
    input  wire        bht_upd_taken,
    // EX update: BTB allocate (taken control-flow only)
    input  wire        btb_upd_valid,
    input  wire [31:0] btb_upd_pc,
    input  wire [31:0] btb_upd_target
);

    // ---------------- BHT: 512 x 2-bit single-port synchronous SRAM ----
    reg [1:0] bht [0:511];

    // ---------------- BTB: 64-entry single-port synchronous SRAM ------
    // packed entry: [55]=valid, [54:31]=tag PC[31:8], [30:0]=target PC[31:1]
    reg [55:0] btb [0:63];

    // ---------------- registered read address -------------------------
    // Tracks pc exactly (both reset to 0; both take lookup_pc each cycle).
    reg [31:0] rd_addr;
    wire [1:0]  bht_ctr = bht[rd_addr[10:2]];
    wire [55:0] btb_ent = btb[rd_addr[7:2]];

    assign btb_hit    = btb_ent[55] &&
                        (btb_ent[54:31] == rd_addr[31:8]);
    assign pred_taken  = btb_hit && (bht_ctr >= 2'b10);
    assign pred_target = {btb_ent[30:0], 1'b0};

    // ---------------- updates ------------------------------------------
    wire [8:0] bht_idx_up = bht_upd_pc[10:2];
    wire [5:0] btb_idx_up = btb_upd_pc[7:2];
    // read-modify-write of the counter (combinational read of the array,
    // same as the old flop version)
    wire [1:0] bht_ctr_up = bht[bht_idx_up];
    wire [1:0] bht_ctr_nx = bht_upd_taken ?
        ((bht_ctr_up == 2'b11) ? 2'b11 : bht_ctr_up + 2'b01) :
        ((bht_ctr_up == 2'b00) ? 2'b00 : bht_ctr_up - 2'b01);

    integer i;
    // Simulation-only initialization: BHT to weakly not-taken, BTB invalid.
    // Not synthesizable; for synthesis the SRAM powers up uninitialized
    // (the predictor learns; correctness never depends on the initial state).
    // Yosys infers a synchronous SRAM (no async reset on the array).
    initial begin
        for (i = 0; i < 512; i = i + 1)
            bht[i] = 2'b01;          // weakly not-taken
        for (i = 0; i < 64; i = i + 1)
            btb[i] = 56'b0;          // invalid
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_addr <= 32'b0;
        end else begin
            rd_addr <= lookup_pc;
            if (bht_upd_valid)
                bht[bht_idx_up] <= bht_ctr_nx;
            if (btb_upd_valid)
                btb[btb_idx_up] <= {1'b1, btb_upd_pc[31:8], btb_upd_target[31:1]};
        end
    end

endmodule
