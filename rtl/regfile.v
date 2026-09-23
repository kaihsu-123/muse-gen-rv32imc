// ---------------------------------------------------------------------------
// regfile.v - 32x32 register file, 2 async read ports, 1 sync write port.
// x0 is hardwired to zero. Write-first bypass on read-during-write to same
// address: REQUIRED for correctness -- it covers the WB->ID same-cycle
// read (distance-3 RAW: producer in WB, consumer in ID). EX-stage
// forwarding only reaches the EX stage, so it cannot cover this case.
// (The bypass data input is wb_data; keep that path short -- see Fix 1 in
// rv32imc_top.v where the WB link-address adder was pipelined.)
// ---------------------------------------------------------------------------
`timescale 1ns/1ps

module regfile (
    input  wire        clk,
    input  wire        we,
    input  wire [4:0]  waddr,
    input  wire [31:0] wdata,
    input  wire [4:0]  raddr1,
    input  wire [4:0]  raddr2,
    output wire [31:0] rdata1,
    output wire [31:0] rdata2
);

    reg [31:0] regs [0:31];

    integer i;
    initial begin
        for (i = 0; i < 32; i = i + 1)
            regs[i] = 32'b0;
    end

    // Synchronous write (x0 not writable)
    always @(posedge clk) begin
        if (we && (waddr != 5'b0))
            regs[waddr] <= wdata;
    end

    // Asynchronous reads with write-bypass (see header comment)
    assign rdata1 = (raddr1 == 5'b0) ? 32'b0 :
                    (we && (waddr == raddr1) && (waddr != 5'b0)) ? wdata : regs[raddr1];
    assign rdata2 = (raddr2 == 5'b0) ? 32'b0 :
                    (we && (waddr == raddr2) && (waddr != 5'b0)) ? wdata : regs[raddr2];

endmodule
