// ---------------------------------------------------------------------------
// compressed_decoder.v - RV32C decompressor (decode stage)
// Input: 16-bit compressed instruction (low halfword of fetch).
// Output: equivalent 32-bit RV32I/M instruction, plus illegal flag.
// Plain Verilog-2001, Yosys compatible.
// ---------------------------------------------------------------------------
`timescale 1ns/1ps

module compressed_decoder (
    input  wire [15:0] cin,
    output reg  [31:0] cout,
    output reg         illegal
);

    wire [1:0] op     = cin[1:0];
    wire [2:0] funct3 = cin[15:13];
    wire [4:0] rd_rs1 = cin[11:7];
    wire [4:0] rs2    = cin[6:2];
    wire [2:0] rs1s   = cin[9:7];   // compressed rs1'
    wire [2:0] rs2s   = cin[4:2];   // compressed rs2'/rd'

    // J-type immediate for C.J / C.JAL
    wire [31:0] c_j_imm = {{20{cin[12]}}, cin[12], cin[8], cin[10], cin[9],
                            cin[6], cin[7], cin[2], cin[11], cin[5], cin[4], cin[3], 1'b0};
    // B-type immediate for C.BEQZ / C.BNEZ
    wire [31:0] c_b_imm = {{23{cin[12]}}, cin[12], cin[6], cin[5], cin[2],
                            cin[11], cin[10], cin[4], cin[3], 1'b0};
    // 6-bit sign-extended immediates
    wire [31:0] c_imm6  = {{26{cin[12]}}, cin[12], cin[6:2]};
    wire [5:0]  c_shamt = {cin[12], cin[6:2]};

    // Quadrant 0 / 2 immediates (12-bit, I/S-type shaped)
    wire [11:0] q0_4spn_imm = {2'b00, cin[10:7], cin[12:11], cin[5], cin[6], 2'b00};
    wire [11:0] q0_lwsw_imm = {5'b0, cin[5], cin[12:10], cin[6], 2'b00};
    wire [11:0] q2_lwsp_imm = {4'b0, cin[3:2], cin[12], cin[6:4], 2'b00};
    wire [11:0] q2_swsp_imm = {4'b0, cin[8:7], cin[12:9], 2'b00};
    wire [11:0] q1_16sp_imm = {{2{cin[12]}}, cin[12], cin[4:3], cin[5], cin[2], cin[6], 4'b0};

    // RV32I opcode constants
    localparam OP_IMM   = 7'b0010011;
    localparam OP_OP    = 7'b0110011;
    localparam OP_LOAD  = 7'b0000011;
    localparam OP_STORE = 7'b0100011;
    localparam OP_BRANCH= 7'b1100011;
    localparam OP_JAL   = 7'b1101111;
    localparam OP_JALR  = 7'b1100111;
    localparam OP_LUI   = 7'b0110111;

    always @(*) begin
        illegal = 1'b0;
        cout    = 32'b0;

        case ({funct3, op})
            // ---------------- Quadrant 0 ----------------
            // C.ADDI4SPN -> addi rd', x2, nzuimm
            5'b000_00: begin
                if (q0_4spn_imm == 12'b0)
                    illegal = 1'b1;
                else
                    cout = {q0_4spn_imm, 5'd2, 3'b000, {2'b01, rs2s}, OP_IMM};
            end
            // C.LW -> lw rd', uimm(rs1')
            5'b010_00: begin
                cout = {q0_lwsw_imm, {2'b01, rs1s}, 3'b010, {2'b01, rs2s}, OP_LOAD};
            end
            // C.SW -> sw rs2', uimm(rs1')
            5'b110_00: begin
                cout = {q0_lwsw_imm[11:5], {2'b01, rs2s}, {2'b01, rs1s},
                        3'b010, q0_lwsw_imm[4:0], OP_STORE};
            end
            // ---------------- Quadrant 1 ----------------
            // C.ADDI -> addi rd, rd, imm
            // (rd=x0,imm=0 is C.NOP, a valid HINT; rd=x0 otherwise is also HINT)
            5'b000_01: begin
                cout = {c_imm6[11:0], rd_rs1, 3'b000, rd_rs1, OP_IMM};
            end
            // C.JAL -> jal x1, offset
            5'b001_01: begin
                cout = {c_j_imm[20], c_j_imm[10:1], c_j_imm[11], c_j_imm[19:12],
                        5'd1, OP_JAL};
            end
            // C.LI -> addi rd, x0, imm
            5'b010_01: begin
                if (rd_rs1 == 5'b0)
                    illegal = 1'b1;
                else
                    cout = {c_imm6[11:0], 5'b0, 3'b000, rd_rs1, OP_IMM};
            end
            // C.LUI / C.ADDI16SP
            5'b011_01: begin
                if (rd_rs1 == 5'd2) begin
                    // C.ADDI16SP -> addi x2, x2, nzimm
                    if (q1_16sp_imm == 12'b0)
                        illegal = 1'b1;
                    else
                        cout = {q1_16sp_imm, 5'd2, 3'b000, 5'd2, OP_IMM};
                end else begin
                    // C.LUI -> lui rd, nzimm<<12 (nzimm sign-extended)
                    if (rd_rs1 == 5'b0 || c_imm6[5:0] == 6'b0)
                        illegal = 1'b1;
                    else
                        cout = {c_imm6[19:0], rd_rs1, OP_LUI};
                end
            end
            // C.SRLI / C.SRAI / C.ANDI / C.SUB / C.XOR / C.OR / C.AND
            5'b100_01: begin
                case (cin[11:10])
                    2'b00: begin // C.SRLI
                        if (c_shamt[5]) illegal = 1'b1;
                        else cout = {7'b0, c_shamt[4:0], {2'b01, rs1s}, 3'b101,
                                     {2'b01, rs1s}, OP_IMM};
                    end
                    2'b01: begin // C.SRAI
                        if (c_shamt[5]) illegal = 1'b1;
                        else cout = {7'b0100000, c_shamt[4:0], {2'b01, rs1s}, 3'b101,
                                     {2'b01, rs1s}, OP_IMM};
                    end
                    2'b10: begin // C.ANDI
                        cout = {c_imm6[11:0], {2'b01, rs1s}, 3'b111, {2'b01, rs1s}, OP_IMM};
                    end
                    2'b11: begin // register-register
                        case (cin[6:5])
                            2'b00: cout = {7'b0100000, {2'b01, rs2s}, {2'b01, rs1s},
                                           3'b000, {2'b01, rs1s}, OP_OP}; // C.SUB
                            2'b01: cout = {7'b0000000, {2'b01, rs2s}, {2'b01, rs1s},
                                           3'b100, {2'b01, rs1s}, OP_OP}; // C.XOR
                            2'b10: cout = {7'b0000000, {2'b01, rs2s}, {2'b01, rs1s},
                                           3'b110, {2'b01, rs1s}, OP_OP}; // C.OR
                            2'b11: cout = {7'b0000000, {2'b01, rs2s}, {2'b01, rs1s},
                                           3'b111, {2'b01, rs1s}, OP_OP}; // C.AND
                        endcase
                    end
                endcase
            end
            // C.J -> jal x0, offset
            5'b101_01: begin
                cout = {c_j_imm[20], c_j_imm[10:1], c_j_imm[11], c_j_imm[19:12],
                        5'd0, OP_JAL};
            end
            // C.BEQZ -> beq rs1', x0, offset
            5'b110_01: begin
                cout = {c_b_imm[12], c_b_imm[10:5], 5'b0, {2'b01, rs1s},
                        3'b000, c_b_imm[4:1], c_b_imm[11], OP_BRANCH};
            end
            // C.BNEZ -> bne rs1', x0, offset
            5'b111_01: begin
                cout = {c_b_imm[12], c_b_imm[10:5], 5'b0, {2'b01, rs1s},
                        3'b001, c_b_imm[4:1], c_b_imm[11], OP_BRANCH};
            end
            // ---------------- Quadrant 2 ----------------
            // C.SLLI -> slli rd, rd, shamt
            5'b000_10: begin
                if (rd_rs1 == 5'b0 || c_shamt[5])
                    illegal = 1'b1;
                else
                    cout = {7'b0, c_shamt[4:0], rd_rs1, 3'b001, rd_rs1, OP_IMM};
            end
            // C.LWSP -> lw rd, uimm(x2)
            5'b010_10: begin
                if (rd_rs1 == 5'b0)
                    illegal = 1'b1;
                else
                    cout = {q2_lwsp_imm, 5'd2, 3'b010, rd_rs1, OP_LOAD};
            end
            // C.JR / C.MV / C.EBREAK / C.JALR / C.ADD
            5'b100_10: begin
                if (cin[12] == 1'b0) begin
                    if (rs2 == 5'b0) begin
                        if (rd_rs1 == 5'b0)
                            illegal = 1'b1;              // reserved
                        else
                            cout = {12'b0, rd_rs1, 3'b000, 5'b0, OP_JALR}; // C.JR
                    end else begin
                        if (rd_rs1 == 5'b0)
                            illegal = 1'b1;              // hint reserved
                        else
                            cout = {7'b0, rs2, 5'b0, 3'b000, rd_rs1, OP_OP}; // C.MV
                    end
                end else begin
                    if (rs2 == 5'b0) begin
                        if (rd_rs1 == 5'b0)
                            cout = 32'h00000073;         // C.EBREAK
                        else
                            cout = {12'b0, rd_rs1, 3'b000, 5'd1, OP_JALR}; // C.JALR
                    end else begin
                        if (rd_rs1 == 5'b0)
                            illegal = 1'b1;
                        else
                            cout = {7'b0, rs2, rd_rs1, 3'b000, rd_rs1, OP_OP}; // C.ADD
                    end
                end
            end
            // C.SWSP -> sw rs2, uimm(x2)
            5'b110_10: begin
                cout = {q2_swsp_imm[11:5], rs2, 5'd2,
                        3'b010, q2_swsp_imm[4:0], OP_STORE};
            end
            default: illegal = 1'b1;
        endcase
    end

endmodule
