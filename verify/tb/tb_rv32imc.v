////////////////////////////////////////////////////////////////////////////////
// tb_rv32imc.v -- functional testbench for the RV32IMC 5-stage CPU
//
// Loads a program hex (Verilog $readmemh format, 32-bit words, little-endian)
// into a single-cycle memory model, releases reset, then watches the data
// bus for writes to the `tohost` address (riscv-tests protocol):
//    wdata == 1              -> TEST PASS
//    wdata == (id<<24)|value -> benchmark report (id, value), keeps running
//    wdata == anything else  -> TEST FAIL (test number = wdata >> 1)
// A cycle timeout also counts as FAIL.
//
// Plusargs:
//    +hex=<file>       program hex to load            (default: test.hex)
//    +tohost=<hexaddr> tohost byte address, e.g. 0x1200 (default: 0x0 = disabled)
//    +timeout=<cycles> watchdog cycles                (default: 5000000)
//    +vcd=<file>       enable VCD dump to <file>      (default: off)
//    +imem_wait_pat=<0|1|2> imem_wait stimulus: 0=never, 1=LFSR random,
//                      2=window [+wait_win0,+wait_win1)  (default: 0)
//    +dmem_wait_pat=<0|1|2> dmem_wait stimulus (same coding; pattern 1/2
//                      only assert while dmem_en)         (default: 0)
//    +wait_win0=<n> +wait_win1=<n>  window bounds (post-reset cycles)
//    +wait_seed=<hex> LFSR seed                        (default: ACE1)
//
// A store to 0xFFFF0000 (magic MMIO) overwrites the DUT's mip_in.
//
// DUT INTERFACE CONTRACT (see ../README.md):
//   The DUT must be named `rv32imc_top` with the ports below. If the RTL
//   uses a different bus/handshake, adapt ONLY the marked "ADAPTER" section.
////////////////////////////////////////////////////////////////////////////////
`timescale 1ns / 1ps

module tb_rv32imc;

  // ------------------------------------------------------------------
  // Parameters
  // ------------------------------------------------------------------
  parameter MEM_WORDS = 32768;          // 128 KiB unified backing memory
  localparam AW = $clog2(MEM_WORDS);    // word-index width

  reg         clk;
  reg         rst_n;

  // ================= DUT INTERFACE (ADAPTER: edit here if RTL differs) =====
  // Matches rtl/rv32imc_top.v as built by the RTL task:
  //   - imem: no read-enable, combinational read, + imem_wait stall input
  //   - dmem: dmem_en + dmem_wstrb (byte strobes, 0 = read) + dmem_wait
  //   - mip_in: machine interrupt pending lines (level)
  wire [31:0] imem_addr;
  wire [31:0] imem_rdata;
  wire [31:0] dmem_addr;
  wire        dmem_en;
  wire [31:0] dmem_wdata;
  wire [3:0]  dmem_wstrb;
  wire [31:0] dmem_rdata;
  wire [31:0] dbg_pc;
  wire [31:0] dbg_instr;
  wire        dbg_valid;

  // ---- wait / interrupt stimulus (plusarg-controlled; default all off) ----
  // +imem_wait_pat / +dmem_wait_pat: 0 = never (default), 1 = LFSR pseudo
  //   random, 2 = asserted in window [+wait_win0, +wait_win1) post-reset
  //   cycles, 3 = SoC SDRAM-like address-change-triggered 2-wait
  //   (COMBINATIONAL: new address asserts wait in the same cycle).
  //   +wait_seed sets the LFSR seed (default 0xACE1).
  // A store to 0xFFFF0000 (magic MMIO, not real memory) overwrites mip_in.
  reg         imem_wait_r;
  reg         dmem_wait_r;
  reg [31:0]  mip_r;
  reg [15:0]  wlfsr;
  reg [63:0]  cycle_cnt;   // post-reset cycle counter (also used by watchdog)
  integer     imem_wait_pat, dmem_wait_pat;
  integer     wait_win0, wait_win1;
  reg [15:0]  wait_seed;

  // Pattern 3: SoC SDRAM-like address-change-triggered 2-wait.
  // COMBINATIONAL: a new address asserts wait in the same cycle (via i_new /
  // d_new), then the counter runs for 2 cycles. This is the stimulus that
  // exposed the wait x mispredict corner (registered patterns never assert
  // wait in the exact resolve cycle of a redirect).
  reg [31:0] i_addr_q3;
  reg [1:0]  icnt3;
  reg [31:0] d_addr_q3;
  reg [1:0]  dcnt3;
  wire i_new3 = (imem_addr != i_addr_q3);
  wire d_new3 = dmem_en && (dmem_addr != d_addr_q3);
  wire imem_wait_p3 = i_new3 || (icnt3 < 2'd2);
  wire dmem_wait_p3 = dmem_en && (d_new3 || (dcnt3 < 2'd2));
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      i_addr_q3 <= 32'd0; icnt3 <= 2'd0;
      d_addr_q3 <= 32'd0; dcnt3 <= 2'd0;
    end else begin
      if (i_new3) begin i_addr_q3 <= imem_addr; icnt3 <= 2'd0; end
      else if (icnt3 < 2'd2) icnt3 <= icnt3 + 2'd1;
      if (d_new3) begin d_addr_q3 <= dmem_addr; dcnt3 <= 2'd0; end
      else if (dmem_en && dcnt3 < 2'd2) dcnt3 <= dcnt3 + 2'd1;
    end
  end
  // Select registered (patterns 0-2) vs combinational (pattern 3) waits.
  wire imem_wait = (imem_wait_pat == 3) ? imem_wait_p3 : imem_wait_r;
  wire dmem_wait = (dmem_wait_pat == 3) ? dmem_wait_p3 : dmem_wait_r;

  rv32imc_top dut (
    .clk        (clk),
    .rst_n      (rst_n),
    // instruction port (Harvard, single-cycle)
    .imem_addr  (imem_addr),
    .imem_rdata (imem_rdata),
    .imem_wait  (imem_wait),
    // data port (Harvard, single-cycle)
    .dmem_en    (dmem_en),
    .dmem_addr  (dmem_addr),
    .dmem_wdata (dmem_wdata),
    .dmem_wstrb (dmem_wstrb),
    .dmem_rdata (dmem_rdata),
    .dmem_wait  (dmem_wait),
    // interrupt lines
    .mip_in     (mip_r),
    // debug observation
    .dbg_pc     (dbg_pc),
    .dbg_instr  (dbg_instr),
    .dbg_valid  (dbg_valid)
  );
  // ================= END ADAPTER ============================================

  // ---- wait-pattern generators ----
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wlfsr       <= wait_seed;
      imem_wait_r <= 1'b0;
      dmem_wait_r <= 1'b0;
      mip_r       <= 32'b0;
    end else begin
      wlfsr <= {wlfsr[14:0], wlfsr[15] ^ wlfsr[13] ^ wlfsr[12] ^ wlfsr[10]};
      case (imem_wait_pat)
        1: imem_wait_r <= (wlfsr[11:6] < 6'd6);   // ~9% pseudo-random
        2: imem_wait_r <= (cycle_cnt >= wait_win0) && (cycle_cnt < wait_win1);
        default: imem_wait_r <= 1'b0;
      endcase
      case (dmem_wait_pat)
        // only meaningful while a request is active; the CPU holds the
        // request so a multi-cycle LFSR run becomes a multi-cycle wait
        1: dmem_wait_r <= dmem_en && (wlfsr[5:0] < 6'd8);  // ~12% when active
        2: dmem_wait_r <= dmem_en &&
                          (cycle_cnt >= wait_win0) && (cycle_cnt < wait_win1);
        default: dmem_wait_r <= 1'b0;
      endcase
    end
  end

  // ---- derived bus signals used by the monitor/memory model ----
  // A transaction completes only when its wait is deasserted; while
  // dmem_wait is high the CPU holds the request and the TB commits nothing.
  wire        imem_re  = 1'b1;
  wire        dmem_re  = dmem_en && (dmem_wstrb == 4'h0);
  wire        dmem_we  = dmem_en && (dmem_wstrb != 4'h0) && !dmem_wait;
  wire [3:0]  dmem_be  = dmem_wstrb;
  localparam [31:0] MIP_MMIO = 32'hFFFF0000;  // write here overwrites mip_in

  // ------------------------------------------------------------------
  // Single-cycle memory model (shared backing for I and D ports)
  // ------------------------------------------------------------------
  reg [31:0] mem [0:MEM_WORDS-1];
  integer i;

  initial begin
    for (i = 0; i < MEM_WORDS; i = i + 1)
      mem[i] = 32'h00000013;            // NOP (addi x0, x0, 0) = safe default
  end

  // imem: combinational read
  assign imem_rdata = mem[imem_addr[AW+1:2]];

  // dmem: combinational read, synchronous byte-enabled write
  assign dmem_rdata = mem[dmem_addr[AW+1:2]];

  always @(posedge clk) begin
    if (dmem_we) begin
      if (dmem_addr == MIP_MMIO) begin
        mip_r <= dmem_wdata;   // magic MMIO: drive interrupt pending lines
      end else begin
        if (dmem_be[0]) mem[dmem_addr[AW+1:2]][ 7: 0] <= dmem_wdata[ 7: 0];
        if (dmem_be[1]) mem[dmem_addr[AW+1:2]][15: 8] <= dmem_wdata[15: 8];
        if (dmem_be[2]) mem[dmem_addr[AW+1:2]][23:16] <= dmem_wdata[23:16];
        if (dmem_be[3]) mem[dmem_addr[AW+1:2]][31:24] <= dmem_wdata[31:24];
      end
    end
  end

  // ------------------------------------------------------------------
  // Clock / reset
  // ------------------------------------------------------------------
  initial clk = 1'b0;
  always #5 clk = ~clk;                 // 100 MHz functional clock

  initial begin
    rst_n = 1'b0;
    repeat (20) @(posedge clk);
    rst_n = 1'b1;
  end

  // ------------------------------------------------------------------
  // Program load + plusargs
  // ------------------------------------------------------------------
  reg [8*256-1:0] hexfile;
  reg [8*256-1:0] vcdfilename;
  reg [31:0] tohost_addr;
  reg [63:0] timeout_cycles;
  reg        done;

  initial begin
    done = 1'b0;
    cycle_cnt = 64'd0;
    if (!$value$plusargs("hex=%s", hexfile))      hexfile = "test.hex";
    if (!$value$plusargs("tohost=%h", tohost_addr)) tohost_addr = 32'h0;
    if (!$value$plusargs("timeout=%d", timeout_cycles)) timeout_cycles = 64'd5000000;
    if (!$value$plusargs("imem_wait_pat=%d", imem_wait_pat)) imem_wait_pat = 0;
    if (!$value$plusargs("dmem_wait_pat=%d", dmem_wait_pat)) dmem_wait_pat = 0;
    if (!$value$plusargs("wait_win0=%d", wait_win0)) wait_win0 = 0;
    if (!$value$plusargs("wait_win1=%d", wait_win1)) wait_win1 = 0;
    if (!$value$plusargs("wait_seed=%h", wait_seed)) wait_seed = 16'hACE1;
    $readmemh(hexfile, mem);
    $display("[TB] loaded program: %0s", hexfile);
    $display("[TB] tohost addr   : 0x%08h", tohost_addr);
    $display("[TB] timeout cycles: %0d", timeout_cycles);
    if ($value$plusargs("vcd=%s", vcdfilename)) begin
      $dumpfile(vcdfilename);
      $dumpvars(0, tb_rv32imc);
      $display("[TB] VCD dump     : %0s", vcdfilename);
    end
  end

  // ------------------------------------------------------------------
  // tohost monitor: pass / fail / benchmark reports
  // ------------------------------------------------------------------
  reg [31:0] last_report_id;
  reg [31:0] last_report_val;

  always @(posedge clk) begin
    if (rst_n && !done && dmem_we && (dmem_addr == tohost_addr) && (tohost_addr != 32'h0)) begin
      if (dmem_wdata == 32'h00000001) begin
        $display("[TB] RESULT: PASS  after %0d cycles", cycle_cnt);
        done = 1'b1;
        $finish;
      end else if (dmem_wdata[31:24] != 8'h00) begin
        // benchmark report word: {id[31:24], value[23:0]}
        last_report_id  <= dmem_wdata[31:24];
        last_report_val <= dmem_wdata[23:0];
        $display("[TB] REPORT id=%0d value=%0d (0x%06h)", dmem_wdata[31:24],
                 dmem_wdata[23:0], dmem_wdata[23:0]);
      end else begin
        $display("[TB] RESULT: FAIL  testnum=%0d (raw=0x%08h) after %0d cycles",
                 dmem_wdata >> 1, dmem_wdata, cycle_cnt);
        done = 1'b1;
        $finish;
      end
    end
  end

  // ------------------------------------------------------------------
  // Watchdog
  // ------------------------------------------------------------------
  always @(posedge clk) begin
    if (rst_n && !done) begin
      cycle_cnt <= cycle_cnt + 64'd1;
      if (cycle_cnt >= timeout_cycles) begin
        $display("[TB] RESULT: TIMEOUT after %0d cycles", cycle_cnt);
        done = 1'b1;
        $finish;
      end
    end
  end

endmodule
