// ---------------------------------------------------------------------------
// tb_smoke.v - smoke test for rv32imc_top (hand-assembled program)
// Tests: ALU, load/store + load-use hazard, branches, JAL, MUL/DIV/REM,
//        CSR access, ecall trap -> handler -> mret.
// Run: iverilog -o tb_smoke.vvp tb_smoke.v <rtl files...> && vvp tb_smoke.vvp
// ---------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_smoke;

    reg clk = 0;
    reg rst_n = 0;
    always #5 clk = ~clk;

    // ---- instruction memory (4KB @ 0x0, combinational read) ----
    reg [31:0] imem [0:1023];
    wire [31:0] imem_addr;
    wire [31:0] imem_rdata;
    assign imem_rdata = imem[imem_addr[11:2]];

    // ---- data memory (4KB @ 0x1000, byte-addressable) ----
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
        if (dmem_en) begin
            for (b = 0; b < 4; b = b + 1)
                if (dmem_wstrb[b])
                    dmem[dmem_addr[11:0]+b] <= dmem_wdata[b*8+:8];
        end
    end

    wire [31:0] dbg_pc, dbg_instr;
    wire        dbg_valid;

    rv32imc_top dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .imem_addr (imem_addr),
        .imem_rdata(imem_rdata),
        .imem_wait (1'b0),
        .dmem_en   (dmem_en),
        .dmem_addr (dmem_addr),
        .dmem_wdata(dmem_wdata),
        .dmem_wstrb(dmem_wstrb),
        .dmem_rdata(dmem_rdata),
        .dmem_wait (1'b0),
        .mip_in    (32'b0),
        .dbg_pc    (dbg_pc),
        .dbg_instr (dbg_instr),
        .dbg_valid (dbg_valid)
    );

    integer i, errors;

    initial begin
        for (i = 0; i < 1024; i = i + 1) imem[i] = 32'h00000013; // nop
        for (i = 0; i < 4096; i = i + 1) dmem[i] = 8'h0;

        // program
        imem[12'h000>>2] = 32'h10000313; // addi x6, x0, 0x100
        imem[12'h004>>2] = 32'h30531073; // csrw mtvec, x6
        imem[12'h008>>2] = 32'h000012b7; // lui x5, 0x1
        imem[12'h00c>>2] = 32'h00a00093; // addi x1, x0, 10
        imem[12'h010>>2] = 32'h01400113; // addi x2, x0, 20
        imem[12'h014>>2] = 32'h002081b3; // add x3, x1, x2
        imem[12'h018>>2] = 32'h40110233; // sub x4, x2, x1
        imem[12'h01c>>2] = 32'h0032a023; // sw x3, 0(x5)
        imem[12'h020>>2] = 32'h0002a303; // lw x6, 0(x5)
        imem[12'h024>>2] = 32'h00130393; // addi x7, x6, 1   (load-use)
        imem[12'h028>>2] = 32'h00208463; // beq x1, x2, +8   (not taken)
        imem[12'h02c>>2] = 32'h00100413; // addi x8, x0, 1
        imem[12'h030>>2] = 32'h00000463; // beq x0, x0, +8   (taken)
        imem[12'h034>>2] = 32'h00200413; // addi x8, x0, 2   (skipped)
        imem[12'h038>>2] = 32'h00c004ef; // jal x9, +12 -> 0x44 (call), x9=0x3c
        imem[12'h03c>>2] = 32'h00500513; // addi x10, x0, 5 (return target)
        imem[12'h040>>2] = 32'h0080006f; // jal x0, +8 -> 0x48 (skip subroutine)
        imem[12'h044>>2] = 32'h00048067; // jalr x0, 0(x9) (return to 0x3c)
        imem[12'h048>>2] = 32'h022085b3; // mul x11, x1, x2
        imem[12'h04c>>2] = 32'h02114633; // div x12, x2, x1
        imem[12'h050>>2] = 32'h021168b3; // rem x17, x2, x1
        imem[12'h054>>2] = 32'hb00026f3; // csrrs x13, mcycle, x0
        imem[12'h058>>2] = 32'h00000073; // ecall
        imem[12'h05c>>2] = 32'h0aa00813; // addi x16, x0, 0xAA
        imem[12'h060>>2] = 32'h0000006f; // jal x0, 0 (halt)
        // trap handler @ 0x100
        imem[12'h100>>2] = 32'h34101773; // csrrw x14, mepc, x0
        imem[12'h104>>2] = 32'h00470713; // addi x14, x14, 4
        imem[12'h108>>2] = 32'h34171073; // csrw mepc, x14
        imem[12'h10c>>2] = 32'h05500793; // addi x15, x0, 0x55
        imem[12'h110>>2] = 32'h30200073; // mret

        #20 rst_n = 1;

        // wait for x16 == 0xAA (post-mret marker) or timeout
        i = 0;
        while (dut.u_rf.regs[16] !== 32'hAA && i < 3000) begin
            #10;
            i = i + 1;
        end
        if (i >= 3000)
            $display("TIMEOUT waiting for x16");
        #100;

        errors = 0;
        if (dut.u_rf.regs[1]  !== 32'd10)        begin $display("FAIL x1");  errors++; end
        if (dut.u_rf.regs[2]  !== 32'd20)        begin $display("FAIL x2");  errors++; end
        if (dut.u_rf.regs[3]  !== 32'd30)        begin $display("FAIL x3");  errors++; end
        if (dut.u_rf.regs[4]  !== 32'd10)        begin $display("FAIL x4");  errors++; end
        if (dut.u_rf.regs[5]  !== 32'h1000)      begin $display("FAIL x5");  errors++; end
        if (dut.u_rf.regs[6]  !== 32'd30)        begin $display("FAIL x6");  errors++; end
        if (dut.u_rf.regs[7]  !== 32'd31)        begin $display("FAIL x7");  errors++; end
        if (dut.u_rf.regs[8]  !== 32'd1)         begin $display("FAIL x8");  errors++; end
        if (dut.u_rf.regs[9]  !== 32'h3c)        begin $display("FAIL x9");  errors++; end
        if (dut.u_rf.regs[10] !== 32'd5)         begin $display("FAIL x10"); errors++; end
        if (dut.u_rf.regs[11] !== 32'd200)       begin $display("FAIL x11"); errors++; end
        if (dut.u_rf.regs[12] !== 32'd2)         begin $display("FAIL x12"); errors++; end
        if (dut.u_rf.regs[13] == 32'd0)          begin $display("FAIL x13"); errors++; end
        if (dut.u_rf.regs[14] !== 32'h5c)        begin $display("FAIL x14"); errors++; end
        if (dut.u_rf.regs[15] !== 32'h55)        begin $display("FAIL x15"); errors++; end
        if (dut.u_rf.regs[16] !== 32'hAA)        begin $display("FAIL x16"); errors++; end
        if (dut.u_rf.regs[17] !== 32'd0)         begin $display("FAIL x17"); errors++; end
        if ({dmem[3], dmem[2], dmem[1], dmem[0]} !== 32'd30) begin
            $display("FAIL dmem"); errors++;
        end

        if (errors == 0)
            $display("SMOKE TEST PASSED");
        else
            $display("SMOKE TEST FAILED: %0d errors", errors);
        $finish;
    end

endmodule
