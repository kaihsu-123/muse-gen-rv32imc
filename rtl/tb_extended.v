// ---------------------------------------------------------------------------
// tb_extended.v - extended tests: RV32C compressed, MULH/MULHSU/MULHU,
//                DIV/DIVU/REM/REMU edge cases (negatives, div-by-zero)
// Run: iverilog -o tb_ext.vvp tb_extended.v <rtl...> && vvp tb_ext.vvp
// ---------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_extended;

    reg clk = 0;
    reg rst_n = 0;
    always #5 clk = ~clk;

    // ---- instruction memory: 32-bit word memory, combinational read ----
    // (same model as tb_smoke.v and verify/tb/tb_rv32imc.v; the CPU's
    // 16-bit fetch buffer selects the halfword at pc itself)
    reg [31:0] imem [0:1023];
    wire [31:0] imem_addr;
    wire [31:0] imem_rdata;
    assign imem_rdata = imem[imem_addr[11:2]];

    // ---- data memory (4KB @ 0x0) ----
    reg [7:0] dmem [0:4095];
    wire        dmem_en;
    wire [31:0] dmem_addr;
    wire [31:0] dmem_wdata;
    wire [3:0]  dmem_wstrb;
    wire [31:0] dmem_rdata;
    assign dmem_rdata = {dmem[dmem_addr[11:0]+3], dmem[dmem_addr[11:0]+2],
                         dmem[dmem_addr[11:0]+1], dmem[dmem_addr[11:0]+0]};
    integer b;
    always @(posedge clk) begin
        if (dmem_en)
            for (b = 0; b < 4; b = b + 1)
                if (dmem_wstrb[b])
                    dmem[dmem_addr[11:0]+b] <= dmem_wdata[b*8+:8];
    end

    rv32imc_top dut (
        .clk(clk), .rst_n(rst_n),
        .imem_addr(imem_addr), .imem_rdata(imem_rdata), .imem_wait(1'b0),
        .dmem_en(dmem_en), .dmem_addr(dmem_addr),
        .dmem_wdata(dmem_wdata), .dmem_wstrb(dmem_wstrb),
        .dmem_rdata(dmem_rdata), .dmem_wait(1'b0),
        .mip_in(32'b0),
        .dbg_pc(), .dbg_instr(), .dbg_valid()
    );

    integer i, errors;

    initial begin
        for (i = 0; i < 1024; i = i + 1) imem[i] = 32'h00000013; // nop
        for (i = 0; i < 4096; i = i + 1) dmem[i] = 8'h0;

        // Pack two 16-bit instrs per 32-bit word: {high@+2, low@+0}
        imem[0] = {16'h54ed, 16'h0429}; // 0x00: c.addi x8,10 | 0x02: c.li x9,-5
        imem[1] = {16'h9526, 16'h8522}; // 0x04: c.mv x10,x8 | 0x06: c.add x10,x9
        imem[2] = {16'h05fd, 16'ha029}; // 0x08: c.j +10->0x12 | 0x0a: skipped
        imem[3] = {16'h05f5, 16'h05f9}; // 0x0c,0x0e: skipped
        imem[4] = {16'hc019, 16'h05f1}; // 0x10: skipped | 0x12: c.beqz x8,+6 (nt)
        imem[5] = {16'h2021, 16'h0631}; // 0x14: c.addi x12,12 | 0x16: c.jal +8->0x1e
        imem[6] = {16'ha021, 16'h06b5}; // 0x18: c.addi x13,13 | 0x1a: c.j +8->0x22
        imem[7] = {16'h8082, 16'h0739}; // 0x1c: skipped | 0x1e: c.jr x1 ->0x18
        imem[8] = {16'hc008, 16'h07bd}; // 0x20: skipped | 0x22: c.sw x10,0(x8)
        imem[9] = {16'h0001, 16'h400c}; // 0x24: c.lw x11,0(x8) | 0x26: c.nop
        // 32-bit from 0x28 (aligned)
        imem[10] = 32'h80000b37; // 0x28: lui x22,0x80000 (x22=0x80000000)
        imem[11] = 32'hfff00b93; // 0x2c: addi x23,x0,-1 (x23=-1)
        imem[12] = 32'h37b1c33;  // 0x30: mulh x24,x22,x23 (0)
        imem[13] = 32'h37b3cb3;  // 0x34: mulhu x25,x22,x23 (0x7fffffff)
        imem[14] = 32'h37b2d33;  // 0x38: mulhsu x26,x22,x23 (0x80000000)
        imem[15] = 32'h28bcdb3;  // 0x3c: div x27,x23,x8 (0)
        imem[16] = 32'h28bee33;  // 0x40: rem x28,x23,x8 (-1)
        imem[17] = 32'h2044eb3;  // 0x44: div x29,x8,x0 (-1)
        imem[18] = 32'h2046f33;  // 0x48: rem x30,x8,x0 (10)
        imem[19] = 32'h28b5fb3;  // 0x4c: divu x31,x22,x8 (214748364)
        imem[20] = 32'h07f00293; // 0x50: addi x5,x0,0x7F (done marker)
        imem[21] = 32'h0000006f; // 0x54: jal x0,0 (halt)

        #20 rst_n = 1;

        // wait for done marker
        i = 0;
        while (dut.u_rf.regs[5] !== 32'h7F && i < 5000) begin
            #10;
            i = i + 1;
        end
        if (i >= 5000)
            $display("TIMEOUT");
        #100;

        errors = 0;
        // RV32C checks
        if (dut.u_rf.regs[8]  !== 32'd10)         begin $display("FAIL x8 (c.addi)"); errors++; end
        if (dut.u_rf.regs[9]  !== 32'hfffffffb)   begin $display("FAIL x9 (c.li -5)"); errors++; end
        if (dut.u_rf.regs[10] !== 32'd5)          begin $display("FAIL x10 (c.mv/c.add)"); errors++; end
        if (dut.u_rf.regs[11] !== 32'd5)          begin $display("FAIL x11 (c.lw)"); errors++; end
        if (dut.u_rf.regs[12] !== 32'd12)         begin $display("FAIL x12 (c.addi)"); errors++; end
        if (dut.u_rf.regs[13] !== 32'd13)         begin $display("FAIL x13 (c.jal ret)"); errors++; end
        if (dut.u_rf.regs[1]  !== 32'h18)         begin $display("FAIL x1 (c.jal link=pc+2)"); errors++; end
        // MULH checks
        if (dut.u_rf.regs[24] !== 32'h0)          begin $display("FAIL x24 (mulh)"); errors++; end
        if (dut.u_rf.regs[25] !== 32'h7fffffff)   begin $display("FAIL x25 (mulhu)"); errors++; end
        if (dut.u_rf.regs[26] !== 32'h80000000)   begin $display("FAIL x26 (mulhsu)"); errors++; end
        // DIV/REM edge cases
        if (dut.u_rf.regs[27] !== 32'd0)          begin $display("FAIL x27 (div -1/10)"); errors++; end
        if (dut.u_rf.regs[28] !== 32'hffffffff)   begin $display("FAIL x28 (rem -1%%10)"); errors++; end
        if (dut.u_rf.regs[29] !== 32'hffffffff)   begin $display("FAIL x29 (div by 0)"); errors++; end
        if (dut.u_rf.regs[30] !== 32'd10)         begin $display("FAIL x30 (rem by 0)"); errors++; end
        if (dut.u_rf.regs[31] !== 32'd214748364) begin $display("FAIL x31 (divu)"); errors++; end

        if (errors == 0)
            $display("EXTENDED TEST PASSED");
        else
            $display("EXTENDED TEST FAILED: %0d errors", errors);
        $finish;
    end
endmodule
