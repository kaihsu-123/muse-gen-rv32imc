// ---------------------------------------------------------------------------
// mul_div.v - M-extension execution units
//   multiplier : 2-stage (default, start@N->valid@N+2) or experimental 3-stage
//                (MUL_STAGES=3, start@N->valid@N+3) pipelined multiplier
//   divider    : multi-cycle restoring divider, ~34-cycle latency
// Both support flush (branch mispredict / trap). Plain Verilog-2001.
// ---------------------------------------------------------------------------
`timescale 1ns/1ps

// ---------------------------------------------------------------------------
// multiplier: op = 00 MUL, 01 MULH, 10 MULHSU, 11 MULHU
// Parameter STAGES (default 2, override with -DMUL_STAGES=3):
//   2: original 2-stage pipeline, start@N -> valid@N+2. Stage 2 does the
//      33x33 signed multiply in one shot (Yosys builds ~870 ps post-route
//      in ASAP7 RVT -- the fastest of all tried architectures, but still
//      the chip's critical path at 675 ps).
//   3: EXPERIMENTAL 3-stage pipeline, start@N -> valid@N+3. The 33x33
//      multiply is split into two partial products (33x17 and 33x16,
//      ~380 ps post-synth each per the 33x17 experiment) registered in
//      stage 2, plus a final 66-bit add in stage 3. Cycle behavior CHANGES:
//      multiply latency grows by 1 cycle; initiation interval grows with it
//      (the core interface only allows start && !busy, so a new multiply
//      cannot begin until the previous one completes: ~2 cycles for
//      STAGES=2, ~3 cycles for STAGES=3). Not fully pipelined.
// The busy/valid handshake interface is IDENTICAL for both, and the core
// pipeline control (ex_muldiv_stall = wait-for-valid) is latency-agnostic.
// Signedness per RISC-V M: MULH=signed*signed, MULHSU=signed*unsigned,
// MUL/MULHU=unsigned*unsigned. Operands extended to 33 bits so one signed
// 33x33 datapath covers all four ops.
// ---------------------------------------------------------------------------
`ifndef MUL_STAGES
`define MUL_STAGES 2
`endif

module multiplier #(
    parameter STAGES = `MUL_STAGES
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    input  wire [31:0] a,
    input  wire [31:0] b,
    input  wire [1:0]  op,
    input  wire        flush,
    output reg         busy,
    output reg         valid,
    output reg  [31:0] result
);

generate
if (STAGES == 2) begin : g_pipe2
    // ---- stage 1: register operands (fast, no logic) ----------------------
    reg [31:0] a_r, b_r;
    reg [1:0]  op_r;

    // ---- stage 2: sign-select + 33x33 signed multiply ---------------------
    wire        a_signed = (op_r == 2'b01) || (op_r == 2'b10); // MULH, MULHSU
    wire        b_signed = (op_r == 2'b01);                   // MULH only
    wire signed [32:0] a33 = a_signed ? $signed(a_r) : $signed({1'b0, a_r});
    wire signed [32:0] b33 = b_signed ? $signed(b_r) : $signed({1'b0, b_r});
    wire signed [65:0] prod66 = a33 * b33;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy   <= 1'b0;
            valid  <= 1'b0;
            result <= 32'b0;
            a_r <= 32'b0; b_r <= 32'b0; op_r <= 2'b0;
        end else if (flush) begin
            busy  <= 1'b0;
            valid <= 1'b0;
        end else begin
            valid <= 1'b0;
            if (start && !busy) begin
                a_r  <= a;
                b_r  <= b;
                op_r <= op;
                busy <= 1'b1;
            end else if (busy) begin
                // op==00 (MUL) takes low 32; MULH/MULHSU/MULHU take high 32
                result <= (op_r == 2'b00) ? prod66[31:0] : prod66[63:32];
                valid  <= 1'b1;
                busy   <= 1'b0;
            end
        end
    end

end else if (STAGES == 3) begin : g_pipe3
    // ---- stage 1: register operands (fast, no logic) ----------------------
    reg [31:0] a_r, b_r;
    reg [1:0]  op_r;

    wire        a_signed = (op_r == 2'b01) || (op_r == 2'b10); // MULH, MULHSU
    wire        b_signed = (op_r == 2'b01);                   // MULH only
    wire signed [32:0] a33 = a_signed ? $signed(a_r) : $signed({1'b0, a_r});
    wire signed [32:0] b33 = b_signed ? $signed(b_r) : $signed({1'b0, b_r});

    // ---- stage 2: partial products, registered -----------------------------
    // b33 = b_hi * 2^17 + b_lo, where b_hi = b33[32:17] is signed (carries
    // the sign bit) and b_lo = b33[16:0] is the unsigned low part. So
    //   a33*b33 = a33*b_lo + (a33*b_hi) << 17.
    // 33x18 and 33x16 multiplies instead of one 33x33. NOTE: the narrow
    // operands MUST be named wires: writing $signed({1'b0, b33[16:0]})
    // inline makes Yosys widen B to the full result width (33x51!), which
    // is slower than the original 33x33. Named wires keep B at 18/16 bits.
    wire signed [17:0] b_lo = {1'b0, b33[16:0]};
    wire signed [15:0] b_hi = b33[32:17];
    wire signed [50:0] pp0_w = a33 * b_lo;
    wire signed [48:0] pp1_w = a33 * b_hi;
    reg signed [50:0] pp0_r;
    reg signed [48:0] pp1_r;
    reg [1:0] op_r2;

    // ---- stage 3: sum partials (single 66-bit add) + result select ---------
    wire signed [65:0] pp0_ext = pp0_r;   // sign-extended
    wire signed [65:0] pp1_ext = $signed({ {17{pp1_r[48]}}, pp1_r }) <<< 17;
    wire signed [65:0] prod66  = pp0_ext + pp1_ext;

    // pipeline control: st=0 idle, 1 = pp capture pending, 2 = result pending
    // start@N -> valid@N+3; busy high during the two cycles in between.
    reg [1:0] st;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy   <= 1'b0;
            valid  <= 1'b0;
            result <= 32'b0;
            a_r <= 32'b0; b_r <= 32'b0; op_r <= 2'b0;
            pp0_r <= 51'sb0; pp1_r <= 49'sb0; op_r2 <= 2'b0;
            st <= 2'd0;
        end else if (flush) begin
            busy  <= 1'b0;
            valid <= 1'b0;
            st    <= 2'd0;
        end else begin
            valid <= 1'b0;
            case (st)
                2'd0: if (start && !busy) begin
                    a_r  <= a;
                    b_r  <= b;
                    op_r <= op;
                    busy <= 1'b1;
                    st   <= 2'd1;
                end
                2'd1: begin
                    pp0_r  <= pp0_w;
                    pp1_r  <= pp1_w;
                    op_r2  <= op_r;
                    st     <= 2'd2;
                end
                2'd2: begin
                    // op==00 (MUL) takes low 32; MULH/MULHSU/MULHU high 32
                    result <= (op_r2 == 2'b00) ? prod66[31:0] : prod66[63:32];
                    valid  <= 1'b1;
                    busy   <= 1'b0;
                    st     <= 2'd0;
                end
                default: st <= 2'd0;
            endcase
        end
    end

end else begin : g_bad_stages
    initial $error("multiplier: STAGES must be 2 or 3");
end
endgenerate

endmodule

// ---------------------------------------------------------------------------
// divider: op = 00 DIV, 01 DIVU, 10 REM, 11 REMU
// Restoring division, 32 iterations. Latency ~35 cycles incl. setup.
// Handles divide-by-zero and INT_MIN/-1 per RISC-V spec.
// ---------------------------------------------------------------------------
module divider (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    input  wire [31:0] dividend,
    input  wire [31:0] divisor,
    input  wire [1:0]  op,
    input  wire        flush,
    output reg         busy,
    output reg         valid,
    output reg  [31:0] result
);

    localparam S_IDLE = 2'd0;
    localparam S_BUSY = 2'd1;
    localparam S_DONE = 2'd2;

    reg [1:0]  state;
    reg [5:0]  count;
    reg [31:0] divisor_r;
    reg [32:0] rem_r;
    reg [31:0] quot_r;
    reg        dividend_neg;
    reg        divisor_neg;
    reg        is_rem;
    reg        is_signed;
    reg        fast_done; // result already set in S_IDLE (div-by-zero/overflow)

    wire [32:0] rem_shifted = {rem_r[31:0], quot_r[31]};
    wire [32:0] rem_sub     = rem_shifted - {1'b0, divisor_r};
    // next-state values (used for both the iteration update and S_DONE result)
    wire [32:0] rem_next  = rem_sub[32] ? rem_shifted : rem_sub;
    wire [31:0] quot_next = {quot_r[30:0], ~rem_sub[32]};

    wire is_signed_w = (op == 2'b00) || (op == 2'b10);
    wire is_rem_w    = op[1];
    wire div_by_zero = (divisor == 32'b0);
    wire overflow    = is_signed_w && (dividend == 32'h80000000) && (divisor == 32'hFFFFFFFF);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            busy  <= 1'b0;
            valid <= 1'b0;
            result <= 32'b0;
            count <= 6'b0;
            divisor_r <= 32'b0; rem_r <= 33'b0; quot_r <= 32'b0;
            dividend_neg <= 1'b0; divisor_neg <= 1'b0;
            is_rem <= 1'b0; is_signed <= 1'b0;
            fast_done <= 1'b0;
        end else if (flush) begin
            state <= S_IDLE;
            busy  <= 1'b0;
            valid <= 1'b0;
        end else begin
            valid <= 1'b0;
            case (state)
                S_IDLE: begin
                    if (start) begin
                        is_signed    <= is_signed_w;
                        is_rem       <= is_rem_w;
                        dividend_neg <= is_signed_w && dividend[31];
                        divisor_neg  <= is_signed_w && divisor[31];
                        if (div_by_zero) begin
                            // DIV/DIVU -> all ones; REM/REMU -> dividend
                            result <= is_rem_w ? dividend : 32'hFFFFFFFF;
                            state  <= S_DONE;
                            busy   <= 1'b1;
                            fast_done <= 1'b1;
                        end else if (overflow) begin
                            result <= is_rem_w ? 32'b0 : 32'h80000000;
                            state  <= S_DONE;
                            busy   <= 1'b1;
                            fast_done <= 1'b1;
                        end else begin
                            divisor_r <= (is_signed_w && divisor[31]) ? (~divisor + 32'd1) : divisor;
                            quot_r    <= (is_signed_w && dividend[31]) ? (~dividend + 32'd1) : dividend;
                            rem_r     <= 33'b0;
                            count     <= 6'b0;
                            state     <= S_BUSY;
                            busy      <= 1'b1;
                            fast_done <= 1'b0;
                        end
                    end
                end
                S_BUSY: begin
                    rem_r  <= rem_next;
                    quot_r <= quot_next;
                    if (count == 6'd31) begin
                        state <= S_DONE;
                    end else begin
                        count <= count + 6'd1;
                    end
                end
                S_DONE: begin
                    // sign fixup on the FINAL rem_r/quot_r (after 32 iterations)
                    // (skipped for fast_done: result already set in S_IDLE)
                    if (!fast_done) begin
                        if (is_signed) begin
                            if (is_rem)
                                result <= dividend_neg ? (~rem_r[31:0] + 32'd1) : rem_r[31:0];
                            else
                                result <= (dividend_neg ^ divisor_neg) ?
                                          (~quot_r + 32'd1) : quot_r;
                        end else begin
                            result <= is_rem ? rem_r[31:0] : quot_r;
                        end
                    end
                    valid <= 1'b1;
                    busy  <= 1'b0;
                    state <= S_IDLE;
                end
                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
