// ---------------------------------------------------------------------------
// csr.v - Minimal CSR file for RV32IMC (machine mode only)
// Implements: mstatus, mie, mtvec, mscratch, mepc, mcause, mtval, mip,
//             mcycle/h, minstret/h
// Trap handling: on trap_valid, saves pc/cause/tval and clears MIE.
// Plain Verilog-2001, Yosys compatible.
// ---------------------------------------------------------------------------
`timescale 1ns/1ps

module csr (
    input  wire        clk,
    input  wire        rst_n,
    // CSR read/write port (combinational read, sync write)
    input  wire [11:0] addr,
    input  wire        we,
    input  wire [31:0] wdata,
    output wire [31:0] rdata,
    // instruction-retire counter tick (from WB stage)
    input  wire        retire_valid,
    // branch predictor performance ticks (from EX stage)
    input  wire        branch_tick,      // resolving control-flow instruction
    input  wire        mispredict_tick,  // resolving instruction mispredicted
    // trap interface (from control logic, synchronous)
    input  wire        trap_valid,
    input  wire [31:0] trap_cause,
    input  wire [31:0] trap_pc,
    input  wire [31:0] trap_tval,
    output wire [31:0] trap_vector,   // = mtvec (direct mode)
    // mret handling: pipeline asserts mret_valid, jumps to mepc
    input  wire        mret_valid,
    output wire [31:0] mepc_out,
    // external interrupt lines (tie off if unused)
    input  wire [31:0] mip_in,
    output wire        mie_out,        // mstatus.MIE
    output wire [31:0] mie_bits        // mie register (for interrupt pending)
);

    // CSR addresses
    localparam CSR_MSTATUS  = 12'h300;
    localparam CSR_MIE      = 12'h304;
    localparam CSR_MTVEC    = 12'h305;
    localparam CSR_MSCRATCH = 12'h340;
    localparam CSR_MEPC     = 12'h341;
    localparam CSR_MCAUSE   = 12'h342;
    localparam CSR_MTVAL    = 12'h343;
    localparam CSR_MIP      = 12'h344;
    localparam CSR_MCYCLE   = 12'hB00;
    localparam CSR_MCYCLEH  = 12'hB80;
    localparam CSR_MINSTRET = 12'hB02;
    localparam CSR_MINSTRETH= 12'hB82;
    // custom read-only performance counters (branch predictor)
    localparam CSR_BR_EXEC  = 12'h7C0;  // control-flow insns resolved in EX
    localparam CSR_BR_MISP  = 12'h7C1;  // ... of which mispredicted

    reg [31:0] mstatus_r;   // only MIE(3) and MPIE(7) implemented
    reg [31:0] mie_r;
    reg [31:0] mtvec_r;
    reg [31:0] mscratch_r;
    reg [31:0] mepc_r;
    reg [31:0] mcause_r;
    reg [31:0] mtval_r;
    reg [63:0] mcycle_r;
    reg [63:0] minstret_r;
    reg [31:0] br_exec_r;   // 32-bit; wraps (documented)
    reg [31:0] br_misp_r;   // 32-bit; wraps (documented)

    // Pre-incremented values, computed from the flop outputs in parallel
    // with the tick logic (not after it). Bit-identical to
    // "cnt <= cnt + {31'b0, tick}": when tick=0 the flop holds, when
    // tick=1 it takes the precomputed cnt+1. This removes the tick ->
    // carry-chain serial dependency from the critical path.
    wire [63:0] minstret_inc = minstret_r + 64'd1;
    wire [31:0] br_exec_inc  = br_exec_r + 32'd1;
    wire [31:0] br_misp_inc  = br_misp_r + 32'd1;

    wire [31:0] mip_r = mip_in;

    // combinational read
    reg [31:0] rdata_r;
    always @(*) begin
        case (addr)
            CSR_MSTATUS:   rdata_r = mstatus_r;
            CSR_MIE:       rdata_r = mie_r;
            CSR_MTVEC:     rdata_r = mtvec_r;
            CSR_MSCRATCH:  rdata_r = mscratch_r;
            CSR_MEPC:      rdata_r = mepc_r;
            CSR_MCAUSE:    rdata_r = mcause_r;
            CSR_MTVAL:     rdata_r = mtval_r;
            CSR_MIP:       rdata_r = mip_r;
            CSR_MCYCLE:    rdata_r = mcycle_r[31:0];
            CSR_MCYCLEH:   rdata_r = mcycle_r[63:32];
            CSR_MINSTRET:  rdata_r = minstret_r[31:0];
            CSR_MINSTRETH: rdata_r = minstret_r[63:32];
            CSR_BR_EXEC:   rdata_r = br_exec_r;
            CSR_BR_MISP:   rdata_r = br_misp_r;
            default:       rdata_r = 32'b0;
        endcase
    end
    assign rdata = rdata_r;
    assign trap_vector = mtvec_r;
    assign mepc_out = mepc_r;
    assign mie_out = mstatus_r[3];
    assign mie_bits = mie_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mstatus_r  <= 32'b0;
            mie_r      <= 32'b0;
            mtvec_r    <= 32'b0;
            mscratch_r <= 32'b0;
            mepc_r     <= 32'b0;
            mcause_r   <= 32'b0;
            mtval_r    <= 32'b0;
            mcycle_r   <= 64'b0;
            minstret_r <= 64'b0;
            br_exec_r  <= 32'b0;
            br_misp_r  <= 32'b0;
        end else begin
            mcycle_r   <= mcycle_r + 64'd1;
            minstret_r <= retire_valid ? minstret_inc : minstret_r;
            br_exec_r  <= branch_tick ? br_exec_inc : br_exec_r;
            br_misp_r  <= mispredict_tick ? br_misp_inc : br_misp_r;

            if (trap_valid) begin
                // trap takes priority over CSR write
                mepc_r   <= trap_pc;
                mcause_r <= trap_cause;
                mtval_r  <= trap_tval;
                // MPIE <= MIE; MIE <= 0
                mstatus_r[7] <= mstatus_r[3];
                mstatus_r[3] <= 1'b0;
            end else if (mret_valid) begin
                // MIE <= MPIE; MPIE <= 1
                mstatus_r[3] <= mstatus_r[7];
                mstatus_r[7] <= 1'b1;
            end else if (we) begin
                case (addr)
                    CSR_MSTATUS:  mstatus_r  <= {24'b0, wdata[7], 3'b0, wdata[3], 3'b0};
                    CSR_MIE:      mie_r      <= wdata;
                    CSR_MTVEC:    mtvec_r    <= {wdata[31:2], 2'b0};
                    CSR_MSCRATCH: mscratch_r <= wdata;
                    CSR_MEPC:     mepc_r     <= {wdata[31:1], 1'b0};
                    CSR_MCAUSE:   mcause_r   <= wdata;
                    CSR_MTVAL:    mtval_r    <= wdata;
                    default: ;
                endcase
            end
        end
    end

endmodule
