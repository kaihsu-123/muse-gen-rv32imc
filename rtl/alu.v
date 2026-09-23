// ---------------------------------------------------------------------------
// alu.v - RV32I ALU (combinational)
// Supports: ADD SUB SLL SRL SRA XOR OR AND SLT SLTU
// Plain Verilog-2001, Yosys compatible.
// ---------------------------------------------------------------------------
`timescale 1ns/1ps

module alu (
    input  wire [31:0] a,
    input  wire [31:0] b,
    input  wire [3:0]  alu_op,   // 0000 ADD, 0001 SUB, 0010 SLL, 0011 SRL,
                                 // 0100 SRA, 0101 XOR, 0110 OR, 0111 AND,
                                 // 1000 SLT, 1001 SLTU
    output reg  [31:0] result,
    output wire        zero
);

    wire sub    = alu_op[0] || alu_op[3];   // SUB, SLT, SLTU need a-b
    wire [31:0] b_neg = sub ? ~b : b;
    wire [32:0] add_ext = {1'b0, a} + {1'b0, b_neg} + {32'b0, sub};
    wire [31:0] add_res = add_ext[31:0];

    wire [31:0] sll_res = a << b[4:0];
    wire [31:0] srl_res = a >> b[4:0];
    wire [31:0] sra_res = $signed(a) >>> b[4:0];

    // signed / unsigned less-than via subtraction carry/borrow
    wire slt  = (a[31] != b[31]) ? a[31] : add_res[31];
    wire sltu = ~add_ext[32];                    // borrow out -> a < b

    always @(*) begin
        case (alu_op)
            4'b0000: result = add_res;                    // ADD
            4'b0001: result = add_res;                    // SUB
            4'b0010: result = sll_res;                    // SLL
            4'b0011: result = srl_res;                    // SRL
            4'b0100: result = sra_res;                    // SRA
            4'b0101: result = a ^ b;                      // XOR
            4'b0110: result = a | b;                      // OR
            4'b0111: result = a & b;                      // AND
            4'b1000: result = {31'b0, slt};               // SLT
            4'b1001: result = {31'b0, sltu};              // SLTU
            default: result = 32'b0;
        endcase
    end

    assign zero = (result == 32'b0);

endmodule
