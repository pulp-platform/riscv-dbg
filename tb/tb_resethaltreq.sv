/* Copyright 2026 Felsite Technologies Private Limited.
 * Copyright and related rights are licensed under the Solderpad Hardware
 * License, Version 0.51 (the "License"); you may not use this file except in
 * compliance with the License. You may obtain a copy of the License at
 * http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
 * or agreed to in writing, software, hardware and materials distributed under
 * this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
 * CONDITIONS OF ANY KIND, either express or implied. See the License for the
 * specific language governing permissions and limitations under the License.
 *
 * File: tb_resethaltreq.sv
 *
 * Description: Directed, self-checking testbench for the halt-on-reset
 *              request plumbing (dmstatus.hasresethaltreq, the dmcontrol
 *              set/clr bits, and the per-hart resethaltreq output).
 *
 * This drives dm_csrs over DMI, which is where all three of the behaviours
 * under test live. dm_top and dm_obi_top only forward the parameter and wire
 * the output straight through, which elaboration covers.
 *
 * Scope note: this does NOT exercise the hart-side halt sequence (a hart
 * entering Debug Mode out of reset). That needs a hart model driving the
 * debug-ROM handshake over the system bus and is deliberately out of scope
 * here.
 *
 * Run (Verilator >= 5.0):
 *   verilator --binary --timing -Wno-fatal -Isrc \
 *       -I<common_cells>/include -I<common_cells>/src \
 *       src/dm_pkg.sv src/dm_csrs.sv <common_cells>/src/fifo_v3.sv \
 *       tb/tb_resethaltreq.sv --top-module tb_resethaltreq -o tb_rhr
 *   ./obj_dir/tb_rhr
 */

module tb_resethaltreq #(
  parameter int unsigned NrHarts         = 1,
  parameter bit          HasResetHaltReq = 1'b1
) ();

  localparam time ClkPeriod = 10ns;

  logic clk;
  logic rst_n;

  // DMI
  logic         dmi_req_valid, dmi_req_ready;
  dm::dmi_req_t dmi_req;
  logic          dmi_resp_valid, dmi_resp_ready;
  dm::dmi_resp_t dmi_resp;

  // Outputs under test
  logic [NrHarts-1:0] resethaltreq;
  logic [NrHarts-1:0] haltreq, resumereq;
  logic               dmactive, ndmreset, clear_resumeack;
  logic [19:0]        hartsel;

  // Unused outputs
  logic                                    cmd_valid;
  dm::command_t                            cmd;
  logic [dm::ProgBufSize-1:0][31:0]        progbuf;
  logic [dm::DataCount-1:0][31:0]          data_o;
  logic [31:0]                             sbaddress_o, sbdata_o;
  logic sbaddress_write_valid, sbreadonaddr, sbautoincrement;
  logic [2:0] sbaccess;
  logic sbreadondata, sbdata_read_valid, sbdata_write_valid;

  int unsigned errors = 0;
  int unsigned checks = 0;

  // ---------------------------------------------------------------- DUT

  dm::hartinfo_t [NrHarts-1:0] hartinfo;
  assign hartinfo = '0;

  dm_csrs #(
    .NrHarts         (NrHarts),
    .BusWidth        (32),
    .SelectableHarts ({NrHarts{1'b1}}),
    .HasResetHaltReq (HasResetHaltReq)
  ) i_dm_csrs (
    .clk_i                   (clk),
    .rst_ni                  (rst_n),
    .next_dm_addr_i          ('0),
    .testmode_i              (1'b0),
    .dmi_rst_ni              (rst_n),
    .dmi_req_valid_i         (dmi_req_valid),
    .dmi_req_ready_o         (dmi_req_ready),
    .dmi_req_i               (dmi_req),
    .dmi_resp_valid_o        (dmi_resp_valid),
    .dmi_resp_ready_i        (dmi_resp_ready),
    .dmi_resp_o              (dmi_resp),
    .ndmreset_o              (ndmreset),
    .ndmreset_ack_i          (1'b0),
    .dmactive_o              (dmactive),
    .hartinfo_i              (hartinfo),
    .halted_i                ('0),
    .unavailable_i           ('0),
    .resumeack_i             ('0),
    .hartsel_o               (hartsel),
    .haltreq_o               (haltreq),
    .resumereq_o             (resumereq),
    .clear_resumeack_o       (clear_resumeack),
    .resethaltreq_o          (resethaltreq),
    .cmd_valid_o             (cmd_valid),
    .cmd_o                   (cmd),
    .cmderror_valid_i        (1'b0),
    .cmderror_i              (dm::CmdErrNone),
    .cmdbusy_i               (1'b0),
    .progbuf_o               (progbuf),
    .data_o                  (data_o),
    .data_i                  ('0),
    .data_valid_i            (1'b0),
    .sbaddress_o             (sbaddress_o),
    .sbaddress_i             ('0),
    .sbaddress_write_valid_o (sbaddress_write_valid),
    .sbreadonaddr_o          (sbreadonaddr),
    .sbautoincrement_o       (sbautoincrement),
    .sbaccess_o              (sbaccess),
    .sbreadondata_o          (sbreadondata),
    .sbdata_o                (sbdata_o),
    .sbdata_read_valid_o     (sbdata_read_valid),
    .sbdata_write_valid_o    (sbdata_write_valid),
    .sbdata_i                ('0),
    .sbdata_valid_i          (1'b0),
    .sbbusy_i                (1'b0),
    .sberror_valid_i         (1'b0),
    .sberror_i               ('0)
  );

  // ---------------------------------------------------------------- clock

  initial begin
    clk = 1'b0;
    forever #(ClkPeriod/2) clk = ~clk;
  end

  // ---------------------------------------------------------------- DMI bfm

  // Drive on the negedge and sample DUT outputs on the negedge, so nothing
  // races with the non-blocking updates of the posedge the DUT clocks on.
  // The response FIFO is only popped once the response has been observed and
  // captured, so a one-cycle dmi_resp_valid cannot be missed.
  task automatic dmi_xfer(input dm::dtm_op_e op,
                          input logic [6:0]  addr,
                          input logic [31:0] wdata,
                          output logic [31:0] rdata);
    @(negedge clk);
    dmi_req.addr   = addr;
    dmi_req.op     = op;
    dmi_req.data   = wdata;
    dmi_req_valid  = 1'b1;
    dmi_resp_ready = 1'b0;

    // Hold the request until the DM is ready, then the next posedge takes it.
    while (!dmi_req_ready) @(negedge clk);
    @(posedge clk);
    @(negedge clk);
    dmi_req_valid = 1'b0;

    // dmi_resp_valid stays asserted until we pop, so this cannot be missed.
    wait (dmi_resp_valid);
    @(negedge clk);
    rdata          = dmi_resp.data;
    dmi_resp_ready = 1'b1;
    @(posedge clk);
    @(negedge clk);
    dmi_resp_ready = 1'b0;
  endtask

  task automatic dmi_write(input logic [6:0] addr, input logic [31:0] wdata);
    logic [31:0] dummy;
    dmi_xfer(dm::DTM_WRITE, addr, wdata, dummy);
  endtask

  task automatic dmi_read(input logic [6:0] addr, output logic [31:0] rdata);
    dmi_xfer(dm::DTM_READ, addr, 32'h0, rdata);
  endtask

  // Build a dmcontrol word from the struct, so no bit position is assumed.
  function automatic logic [31:0] dmcontrol_word(input bit dmactive_b,
                                                 input bit setrhr,
                                                 input bit clrrhr,
                                                 input int unsigned hart);
    dm::dmcontrol_t d;
    d                  = '0;
    d.dmactive         = dmactive_b;
    d.setresethaltreq  = setrhr;
    d.clrresethaltreq  = clrrhr;
    d.hartsello        = 10'(hart);
    d.hartselhi        = '0;
    return 32'(d);
  endfunction

  // ---------------------------------------------------------------- checks

  task automatic check(input string name, input logic cond);
    checks++;
    if (cond) begin
      $display("  PASS  %s", name);
    end else begin
      errors++;
      $display("  FAIL  %s", name);
    end
  endtask

  // ---------------------------------------------------------------- stimulus

  logic [31:0] rd;
  dm::dmstatus_t dmstatus;

  initial begin
    dmi_req        = '0;
    dmi_req_valid  = 1'b0;
    dmi_resp_ready = 1'b0;
    rst_n          = 1'b0;
    repeat (5) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    $display("tb_resethaltreq: NrHarts=%0d HasResetHaltReq=%0b",
             NrHarts, HasResetHaltReq);

    // Bring the DM up.
    dmi_write(7'(dm::DMControl), dmcontrol_word(1'b1, 1'b0, 1'b0, 0));
    repeat (2) @(posedge clk);

    // ---- 1. dmstatus.hasresethaltreq reflects the parameter -------------
    // The Debug Specification requires a hart with its halt-on-reset bit set
    // to enter Debug Mode out of reset when this is advertised, so it must be
    // the integrator's choice rather than hardwired.
    dmi_read(7'(dm::DMStatus), rd);
    dmstatus = dm::dmstatus_t'(rd);
    check($sformatf("dmstatus.hasresethaltreq == %0b", HasResetHaltReq),
          dmstatus.hasresethaltreq == HasResetHaltReq);

    // ---- 2. setresethaltreq sets the selected hart's bit -----------------
    dmi_write(7'(dm::DMControl), dmcontrol_word(1'b1, 1'b1, 1'b0, 0));
    repeat (2) @(posedge clk);
    check("set -> resethaltreq_o[0] == 1", resethaltreq[0] === 1'b1);

    // ---- 3. the bit persists across an unrelated dmcontrol write ---------
    dmi_write(7'(dm::DMControl), dmcontrol_word(1'b1, 1'b0, 1'b0, 0));
    repeat (2) @(posedge clk);
    check("persists when neither set nor clr is written",
          resethaltreq[0] === 1'b1);

    // ---- 4. clrresethaltreq clears it ------------------------------------
    dmi_write(7'(dm::DMControl), dmcontrol_word(1'b1, 1'b0, 1'b1, 0));
    repeat (2) @(posedge clk);
    check("clr -> resethaltreq_o[0] == 0", resethaltreq[0] === 1'b0);

    // ---- 5. set and clr in the SAME write: clear wins ---------------------
    // "setresethaltreq: ... writes the halt-on-reset request bit for all
    //  currently selected harts, unless clrresethaltreq is simultaneously
    //  set to 1."  (Debug Specification, dmcontrol)
    //
    // Note this was already the behaviour before the change -- the old code
    // applied the clear second, so it won by assignment order. Restructuring
    // it as clr-else-set makes the rule explicit rather than incidental.
    // This case pins the required behaviour so it cannot regress.
    dmi_write(7'(dm::DMControl), dmcontrol_word(1'b1, 1'b1, 1'b1, 0));
    repeat (2) @(posedge clk);
    check("set+clr in one write -> clear wins", resethaltreq[0] === 1'b0);

    // From an already-set state, the same write must still clear.
    dmi_write(7'(dm::DMControl), dmcontrol_word(1'b1, 1'b1, 1'b0, 0));
    repeat (2) @(posedge clk);
    dmi_write(7'(dm::DMControl), dmcontrol_word(1'b1, 1'b1, 1'b1, 0));
    repeat (2) @(posedge clk);
    check("set+clr from a set state -> clear wins", resethaltreq[0] === 1'b0);

    // ---- 6. per-hart independence ----------------------------------------
    if (NrHarts > 1) begin
      dmi_write(7'(dm::DMControl), dmcontrol_word(1'b1, 1'b1, 1'b0, 1));
      repeat (2) @(posedge clk);
      check("set on hart 1 -> resethaltreq_o[1] == 1", resethaltreq[1] === 1'b1);
      check("hart 0 unaffected by a hart 1 set",       resethaltreq[0] === 1'b0);

      dmi_write(7'(dm::DMControl), dmcontrol_word(1'b1, 1'b1, 1'b0, 0));
      repeat (2) @(posedge clk);
      check("both harts can be armed independently",
            resethaltreq[0] === 1'b1 && resethaltreq[1] === 1'b1);

      dmi_write(7'(dm::DMControl), dmcontrol_word(1'b1, 1'b0, 1'b1, 1));
      repeat (2) @(posedge clk);
      check("clr on hart 1 leaves hart 0 armed",
            resethaltreq[0] === 1'b1 && resethaltreq[1] === 1'b0);
    end

    // ---- 7. dmactive = 0 clears the request ------------------------------
    dmi_write(7'(dm::DMControl), dmcontrol_word(1'b1, 1'b1, 1'b0, 0));
    repeat (2) @(posedge clk);
    check("armed before dmactive drop", resethaltreq[0] === 1'b1);
    dmi_write(7'(dm::DMControl), dmcontrol_word(1'b0, 1'b0, 1'b0, 0));
    repeat (3) @(posedge clk);
    check("dmactive = 0 clears resethaltreq_o", resethaltreq === '0);

    // ---------------------------------------------------------------- done
    repeat (4) @(posedge clk);
    $display("tb_resethaltreq: %0d/%0d checks passed", checks - errors, checks);
    if (errors != 0) begin
      $display("TESTS FAILED (%0d)", errors);
      $fatal(1);
    end else begin
      $display("TESTS PASSED");
      $finish;
    end
  end

  // Safety net so a hang is a failure rather than a timeout with no output.
  initial begin
    #(ClkPeriod * 20000);
    $display("TESTS FAILED (timeout)");
    $fatal(1);
  end

endmodule
