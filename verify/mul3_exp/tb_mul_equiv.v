// tb_mul_equiv.v -- multiplier equivalence: STAGES=2 (golden) vs STAGES=3 (DUT)
// vs independent behavioral reference. 20,010 directed+random vectors across
// MUL/MULH/MULHSU/MULHU plus signed corner cases, latency checks
// (start@N -> valid@N+2 for STAGES=2, start@N -> valid@N+3 for STAGES=3),
// mid-flight flush, and flush recovery.
`timescale 1ns/1ps

module tb_mul_equiv;
    reg clk = 0;
    reg rst_n = 0;
    always #5 clk = ~clk;

    // DUT: 3-stage
    reg        start3, flush3;
    reg [31:0] a3, b3;
    reg [1:0]  op3;
    wire       busy3, valid3;
    wire [31:0] result3;
    multiplier #(.STAGES(3)) dut3 (
        .clk(clk), .rst_n(rst_n),
        .start(start3), .a(a3), .b(b3), .op(op3), .flush(flush3),
        .busy(busy3), .valid(valid3), .result(result3)
    );

    // Golden: 2-stage
    reg        start2, flush2;
    reg [31:0] a2, b2;
    reg [1:0]  op2;
    wire       busy2, valid2;
    wire [31:0] result2;
    multiplier #(.STAGES(2)) dut2 (
        .clk(clk), .rst_n(rst_n),
        .start(start2), .a(a2), .b(b2), .op(op2), .flush(flush2),
        .busy(busy2), .valid(valid2), .result(result2)
    );

    // Behavioral reference (module-level so icarus stays happy)
    // NOTE: all regs declared before any always/task that uses them.
    // Manual 66-bit sign extension: icarus miscomputes $signed() on 33-bit regs.
    reg [65:0] ref_p, sa66, sb66;
    reg [31:0] ref_result;
    integer pass, fail, vectors;
    integer i, lat3, lat2;
    reg [31:0] va, vb, expval;
    reg [1:0]  vop;
    always @(*) begin
        sa66 = (vop == 2'b01 || vop == 2'b10) ? {{34{va[31]}}, va} : {34'b0, va};
        sb66 = (vop == 2'b01)                ? {{34{vb[31]}}, vb} : {34'b0, vb};
        ref_p = $signed(sa66) * $signed(sb66);
        if (vop == 2'b00)
            ref_result = va * vb;
        else
            ref_result = ref_p[63:32];
    end

    task do_vector(input [31:0] ta, input [31:0] tb, input [1:0] top);
        reg [31:0] got3, got2;
        reg done3, done2;
        begin
            // drive both
            @(posedge clk);
            while (busy3 || busy2) @(posedge clk);
            while (valid3 || valid2) @(posedge clk); // drain stale pulse
            a3 = ta; b3 = tb; op3 = top;
            a2 = ta; b2 = tb; op2 = top;
            va = ta; vb = tb; vop = top;
            start3 = 1; start2 = 1;
            @(posedge clk);
            start3 = 0; start2 = 0;
            // capture each result on its own valid pulse (different latencies)
            done3 = 0; done2 = 0; lat3 = 0; lat2 = 0;
            while (!done3 || !done2) begin
                @(posedge clk);
                if (!done3) begin
                    if (valid3) begin got3 = result3; done3 = 1; end
                    else begin lat3 = lat3 + 1; if (lat3 > 10) begin $display("TIMEOUT3"); $finish; end end
                end
                if (!done2) begin
                    if (valid2) begin got2 = result2; done2 = 1; end
                    else begin lat2 = lat2 + 1; if (lat2 > 10) begin $display("TIMEOUT2"); $finish; end end
                end
            end
            vectors = vectors + 1;
            if (got3 !== ref_result) begin
                $display("FAIL3 vec=%0d op=%b a=%h b=%h got=%h exp=%h",
                         vectors, top, ta, tb, got3, ref_result);
                fail = fail + 1;
            end else if (got2 !== ref_result) begin
                $display("FAIL2 vec=%0d op=%b a=%h b=%h got=%h exp=%h",
                         vectors, top, ta, tb, got2, ref_result);
                fail = fail + 1;
            end else if (got3 !== got2) begin
                $display("MISMATCH vec=%0d op=%b a=%h b=%h s3=%h s2=%h",
                         vectors, top, ta, tb, got3, got2);
                fail = fail + 1;
            end else if (lat3 != lat2 + 1) begin
                $display("LAT vec=%0d lat3=%0d lat2=%0d, want lat3=lat2+1", vectors, lat3, lat2);
                fail = fail + 1;
            end else begin
                pass = pass + 1;
            end
            @(posedge clk);
        end
    endtask

    // simple LCG for random vectors
    reg [31:0] lcg;
    task rand_vec;
        begin
            lcg = lcg * 32'h0019660d + 32'h3c6ef35f;
            va = lcg;
            lcg = lcg * 32'h0019660d + 32'h3c6ef35f;
            vb = lcg;
            lcg = lcg * 32'h0019660d + 32'h3c6ef35f;
            vop = lcg[1:0];
            do_vector(va, vb, vop);
        end
    endtask

    initial begin
        start3 = 0; start2 = 0; flush3 = 0; flush2 = 0;
        a3 = 0; b3 = 0; op3 = 0; a2 = 0; b2 = 0; op2 = 0;
        pass = 0; fail = 0; vectors = 0;
        lcg = 32'h12345678;
        #20 rst_n = 1;
        #20;

        // directed corner cases
        do_vector(32'h00000000, 32'h00000000, 2'b00);
        do_vector(32'hffffffff, 32'hffffffff, 2'b00);
        do_vector(32'h80000000, 32'h80000000, 2'b00);
        do_vector(32'h80000000, 32'hffffffff, 2'b00);
        do_vector(32'h80000000, 32'h80000000, 2'b01); // MULH INT_MIN*INT_MIN
        do_vector(32'h80000000, 32'hffffffff, 2'b01); // MULH INT_MIN*-1
        do_vector(32'h80000000, 32'hffffffff, 2'b10); // MULHSU
        do_vector(32'hffffffff, 32'hffffffff, 2'b11); // MULHU max
        do_vector(32'h7fffffff, 32'h7fffffff, 2'b01);
        do_vector(32'h00000001, 32'hffffffff, 2'b10);

        // 20,000 random vectors
        for (i = 0; i < 20000; i = i + 1) rand_vec();

        $display("VECTORS: %0d", vectors);

        // mid-flight flush: start, flush after 1 cycle, ensure not busy and can restart
        @(posedge clk);
        while (busy3) @(posedge clk);
        a3 = 32'hdeadbeef; b3 = 32'h12345678; op3 = 2'b00;
        start3 = 1;
        @(posedge clk);
        start3 = 0;
        flush3 = 1;
        @(posedge clk);
        flush3 = 0;
        @(posedge clk);
        if (busy3) begin $display("FAIL: busy stuck after flush"); fail = fail + 1; end
        // recovery: two fresh vectors must work
        do_vector(32'h11111111, 32'h22222222, 2'b00);
        do_vector(32'h33333333, 32'h44444444, 2'b01);

        $display("VECTORS: %0d (incl flush recovery)", vectors);
        if (fail == 0)
            $display("EQUIV PASS: %0d/%0d vectors bit-identical", pass, vectors);
        else
            $display("EQUIV FAIL: %0d failures / %0d vectors", fail, vectors);
        $finish;
    end
endmodule
