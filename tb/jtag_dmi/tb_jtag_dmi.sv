// Copyright 2020 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// Copyright 2026 CheshireAra contributors (directed tests).
// SPDX-License-Identifier: SHL-0.51 AND Apache-2.0

/// Selectively test the JTAG DMI.
module tb_jtag_dmi;

  logic clk, rst_n;

  localparam realtime ClkPeriod = 10ns;
  localparam realtime ApplTime = 2ns;
  localparam realtime TestTime = 8ns;

  localparam realtime JTAGPeriod = 50ns;

  localparam int unsigned AW = 7;
  localparam logic [31:0] IDCode = 32'hdeadbeef | 32'd1;

  // ----------------
  // Clock generation
  // ----------------
  initial begin
    rst_n = 0;
    repeat (3) begin
      #(ClkPeriod / 2) clk = 0;
      #(ClkPeriod / 2) clk = 1;
    end
    rst_n = 1;
    forever begin
      #(ClkPeriod / 2) clk = 0;
      #(ClkPeriod / 2) clk = 1;
    end
  end

  logic tck;

  JTAG_DV jtag_mst (tck);

  initial begin
    #100ns;
    forever begin
      tck = 1;
      #(JTAGPeriod / 2);
      tck = 0;
      #(JTAGPeriod / 2);
    end
  end

  // ---
  // DUT
  // ---
  DMI_BUS_DV #(.ADDR_WIDTH(AW)) slave_dv (clk);

  logic dut_tck, dut_tms, dut_trstn, dut_tdi, dut_tdo;
  logic start_rand;
  bit directed_active = 0, directed_done = 0, random_ready = 0;
  string test_mode = "all";
  // Directed Capture tests adapted from tb/dmi_capture/tb_dmi_capture.sv.
  // Copyright 2026 CheshireAra contributors.
  // This section retains its Apache-2.0 license.
  localparam logic [31:0] Idcode = IDCode;
  string profile = "transport";
  int unsigned case_id = 0, errors = 0, checks = 0, cases = 0;
  bit  stopped = 0;
  time case_started = 0;
  longint unsigned accepted = 0, responses = 0, reset_edges = 0;
  logic old_dmi_rst = 0;
  bit enabled = 0, hold_req = 0, hold_resp = 0;
  int endpoint_mode = 0;
  dm::dmi_req_t wire_req;
  dm::dmi_resp_t wire_resp, stub_resp;
  logic wire_valid, wire_ready, wire_resp_valid, wire_resp_ready, dmi_rst_n;
  logic stub_pending = 0;
  logic [31:0] registers[128];

  dm::dmi_req_t dmi_req;
  dm::dmi_resp_t dmi_resp;

  assign slave_dv.q_addr = dmi_req.addr;
  assign slave_dv.q_op = dmi_req.op;
  assign slave_dv.q_data = dmi_req.data;
  // Only route requests to the endpoint that is running. The directed
  // endpoint checks reset cancellation separately from the random interface.
  assign slave_dv.q_valid = !directed_active && wire_valid;
  assign slave_dv.p_ready = !directed_active && wire_resp_ready;
  assign dmi_resp = directed_active ? wire_resp : '{data: slave_dv.p_data, resp: slave_dv.p_resp};

  dmi_jtag #(
      .IdcodeValue(IDCode)
  ) dut (
      .clk_i(clk),
      .rst_ni(rst_n),
      .testmode_i(1'b0),

      .dmi_rst_no(dmi_rst_n),
      .dmi_req_o(dmi_req),
      .dmi_req_valid_o(wire_valid),
      .dmi_req_ready_i(directed_active ? wire_ready : slave_dv.q_ready),

      .dmi_resp_i(dmi_resp),
      .dmi_resp_ready_o(wire_resp_ready),
      .dmi_resp_valid_i(directed_active ? wire_resp_valid : slave_dv.p_valid),

      .tck_i(dut_tck),
      .tms_i(dut_tms),
      .trst_ni(dut_trstn),
      .td_i(dut_tdi),
      .td_o(dut_tdo),
      .tdo_oe_o()
  );

  // -------
  // Monitor
  // -------
  typedef dmi_test::dmi_monitor#(
      .AW(AW),
      .TA(ApplTime),
      .TT(TestTime)
  ) dmi_monitor_t;

  dmi_monitor_t dmi_monitor = new(slave_dv);

  initial begin
    @(posedge start_rand);
    dmi_monitor.monitor();
  end

  // ------
  // Driver
  // ------
  typedef dmi_test::rand_dmi_slave#(
      // dmi bus interface paramaters;
      .AW(AW),
      // Stimuli application and test time
      .TA(ApplTime),
      .TT(TestTime)
  ) dmi_rand_slave_t;

  dmi_rand_slave_t rand_dmi_slave = new(slave_dv);

  // dmi Slave.
  initial begin
    rand_dmi_slave.reset();
    wait (directed_active || directed_done);
    if (directed_active) run_directed_slave();
    rand_dmi_slave.reset();
    random_ready = 1;
    @(posedge start_rand);
    rand_dmi_slave.run();
  end

`ifdef TARGET_BSCANE

  JTAG_SIME2 #(
      .PART_NAME("7K325T")
  ) i_jtag_sime2 (
      .TDO(jtag_mst.tdo),
      .TCK(tck),
      .TDI(jtag_mst.tdi),
      .TMS(jtag_mst.tms)
  );

  // Default part `7K325T` has an IrLength of 6.
  localparam int unsigned IRLength = i_jtag_sime2.IRLength;
  localparam logic [23:0] IrCaptureVal = 24'b010001010001010001010001,
                          BypassInstr  = 24'b111111111111111111111111,
                          IdcodeInstr  = 24'b001001001001001001001001,
                          User1Instr   = 24'b000010100100100100100100,
                          User2Instr   = 24'b000011100100100100100100,
                          User3Instr   = 24'b100010100100100100100100,
                          User4Instr   = 24'b100011100100100100100100;

  typedef jtag_test::riscv_dbg#(
      .IDCODE(IdcodeInstr[23:(24-IRLength)]),
      .DTMCSR(User3Instr[23:(24-IRLength)]),
      .DMIACCESS(User4Instr[23:(24-IRLength)]),
      .IrLength(IRLength),
      .TA(JTAGPeriod / 10),
      .TT(JTAGPeriod - JTAGPeriod / 10)
  ) riscv_dbg_t;

  /// Helper function to bring instruction register values.
  // initial begin
  //   for (int i = 6; i < 25; i++) begin
  //     $display("IRLength %d: %h %h %h\n", i,
  //       (IDCODE_INSTR >> (24-i)) & (2**i-1),
  //       (USER3_INSTR >> (24-i)) & (2**i-1),
  //       (USER4_INSTR >> (24-i)) & (2**i-1));
  //   end
  // end
`else

  assign dut_tck = tck;
  assign dut_tms = jtag_mst.tms;
  assign dut_trstn = jtag_mst.trst_n;
  assign dut_tdi = jtag_mst.tdi;
  assign jtag_mst.tdo = dut_tdo;

  typedef jtag_test::riscv_dbg#(
      .IrLength(5),
      .TA(JTAGPeriod / 10),
      .TT(JTAGPeriod - JTAGPeriod / 10)
  ) riscv_dbg_t;
`endif

  riscv_dbg_t::jtag_driver_t jtag_in = new(jtag_mst);
  riscv_dbg_t riscv_dbg = new(jtag_in);

  assign wire_ready = !hold_req && !stub_pending && dmi_rst_n;
  assign wire_resp_valid = stub_pending && !hold_resp && dmi_rst_n;
  assign wire_resp = stub_resp;
  assign wire_req = dmi_req;
  always @(posedge clk) begin
    if (case_id != 0 && !stopped && $time - case_started >= 1ms) begin
      stopped = 1;
      $fatal(1, "Directed case timed out.");
    end
    if (enabled) begin
      if (old_dmi_rst === 1 && dmi_rst_n === 0) reset_edges++;
      old_dmi_rst = dmi_rst_n;
      if (rst_n && dmi_rst_n && wire_valid && wire_ready) accepted++;
      if (rst_n && dmi_rst_n && wire_resp_valid && wire_resp_ready) responses++;
      if ((wire_valid && wire_ready) || (wire_resp_valid && wire_resp_ready))
        $display(
            "DMI_HANDSHAKE profile=%s case=%0d req=%b rsp=%b addr=%h op=%h data=%h resp=%h",
            profile,
            case_id,
            wire_valid && wire_ready,
            wire_resp_valid && wire_resp_ready,
            wire_req.addr,
            wire_req.op,
            wire_resp.data,
            wire_resp.resp
        );
    end
  end
  bit dmi_held = 0;
  dm::dmi_req_t held_dmi;
  always @(posedge clk)
    if (enabled) begin
      logic sampled_valid, sampled_ready;
      dm::dmi_req_t sampled_req;
      sampled_valid = wire_valid;
      sampled_ready = wire_ready;
      sampled_req   = wire_req;
      #1ps;
      if (!rst_n || !dmi_rst_n) dmi_held = 0;
      else begin
        if (dmi_held)
          check(sampled_valid === 1 && sampled_req === held_dmi, "dmi_request_hold",
                64'(sampled_req), 64'(held_dmi));
        dmi_held = sampled_valid === 1 && sampled_ready !== 1;
        held_dmi = sampled_req;
      end
    end
  task automatic run_directed_slave;
    while (directed_active) begin
      @(posedge clk);
      if (!rst_n || !dmi_rst_n) stub_pending <= #ApplTime 0;
      else begin
        if (wire_resp_valid && wire_resp_ready) stub_pending <= #ApplTime 0;
        if (wire_valid && wire_ready) begin
          stub_pending <= #ApplTime 1;
          case (endpoint_mode)
            1: stub_resp.resp <= #ApplTime dm::DTM_ERR;
            2: stub_resp.resp <= #ApplTime dm::DTM_BUSY;
            default: stub_resp.resp <= #ApplTime dm::DTM_SUCCESS;
          endcase
          stub_resp.data <= #ApplTime registers[wire_req.addr];
          if (endpoint_mode == 0 && wire_req.op == dm::DTM_WRITE)
            registers[wire_req.addr] = wire_req.data;
        end
      end
    end
    stub_pending = 0;
  endtask
  longint signed tck_edges = 0, last_capture_edge = -1, last_response_edge = -1;
  always @(posedge dut_tck) begin
    tck_edges++;
    if (directed_active && dut.capture && dut.dmi_select) last_capture_edge = tck_edges;
    if (directed_active && dut.dmi_resp_valid && dut.dmi_resp_ready) last_response_edge = tck_edges;
  end
  task automatic fail(input string label, input logic [63:0] actual, input logic [63:0] expected);
    errors++;
    $display("DMI ERROR [%s/%0d] %s: got %h expected %h", profile, case_id, label, actual,
             expected);
  endtask
  task automatic check(input bit good, input string label, input logic [63:0] actual,
                       input logic [63:0] expected);
    checks++;
    if (!good) fail(label, actual, expected);
  endtask
  task automatic limit(input string label);
    stopped = 1;
    $fatal(1, "DMI test [%s/%0d] cannot continue: %s.", profile, case_id, label);
  endtask
  task automatic control(input string label);
    stopped = 1;
    $fatal(1, "DMI test [%s/%0d] cannot continue: %s.", profile, case_id, label);
  endtask
  task automatic begin_case(input int id, input string kind);
    if (stopped) $fatal(1, "Directed test stopped.");
    case_id = id;
    cases++;
    case_started = $time;
    $display("DMI case [%s/%0d] begin: %s", profile, case_id, kind);
  endtask
  task automatic end_case;
    if (stopped) $fatal(1, "Directed test stopped.");
    $display("DMI case [%s/%0d] end: %0d errors", profile, case_id, errors);
    case_id = 0;
  endtask
  task automatic scan_dmi(input logic [40:0] request, output logic [40:0] response);
    riscv_dbg.scan_dmi(request, response);
  endtask
  task automatic scan_dtmcs(input logic [31:0] request, output logic [31:0] response);
    logic tx[$], rx[$];
    if (stopped) $fatal(1, "Directed test stopped.");
    @(posedge tck);
    for (int b = 0; b < 32; b++) tx.push_back(request[b]);
    jtag_in.set_ir(riscv_dbg_t::DTMCSR);
    jtag_in.shift_dr();
    jtag_in.readwrite_bits(rx, tx, 1'b1);
    jtag_in.update_dr(1'b0);
    response = 'x;
    for (int b = 0; b < 32; b++) response[b] = rx[b];
  endtask
  task automatic identity;
    logic tx[$], rx[$];
    logic [31:0] value, dtmcs;
    @(posedge tck);
    for (int b = 0; b < 32; b++) tx.push_back(0);
    jtag_in.set_ir(riscv_dbg_t::IDCODE);
    jtag_in.shift_dr();
    jtag_in.readwrite_bits(rx, tx, 1'b1);
    jtag_in.update_dr(1'b0);
    for (int b = 0; b < 32; b++) value[b] = rx[b];
    check(value === Idcode, "idcode", 64'(value), 64'(Idcode));
    scan_dtmcs(0, dtmcs);
    check(dtmcs === 32'h00001071, "dtmcs_identity", 64'(dtmcs), 64'(32'h1071));
  endtask
  task automatic dmi_write(input logic [6:0] addr, input logic [31:0] value);
    logic [40:0] ignored, response;
    scan_dmi({addr, value, 2'b10}, ignored);
    jtag_in.wait_idle(10);
    scan_dmi(41'd0, response);
    check(response[1:0] === 0, "dmi_write_status", 64'(response[1:0]), 64'(0));
  endtask
  task automatic dmi_read(input logic [6:0] addr, output logic [31:0] value);
    logic [40:0] ignored, response;
    scan_dmi({addr, 32'd0, 2'b01}, ignored);
    jtag_in.wait_idle(10);
    scan_dmi(41'd0, response);
    check(response[1:0] === 0, "dmi_read_status", 64'(response[1:0]), 64'(0));
    value = response[33:2];
  endtask
  task automatic wait_count(input bit response_counter, input longint unsigned wanted);
    for (int n = 0; n < 4096; n++) begin
      if ((response_counter ? responses : accepted) >= wanted) return;
      @(posedge clk);
    end
    limit("transport_handshake");
  endtask
  task automatic wait_request;
    for (int n = 0; n < 4096; n++) begin
      if (wire_valid === 1) return;
      @(posedge clk);
    end
    limit("transport_request_valid");
  endtask
  task automatic reset_sticky;
    logic [31:0] ignored, actual;
    scan_dtmcs(32'h00010000, ignored);
    jtag_in.wait_idle(10);
    scan_dtmcs(0, actual);
    check(actual === 32'h1071, "dtmcs_after_dmireset", 64'(actual), 64'(32'h1071));
  endtask
  task automatic transport_recovery;
    logic [31:0] actual, tag;
    logic [6:0] addr;
    addr = 7'h40 + 7'(case_id);
    tag  = 32'h69a50000 | case_id;
    dmi_write(addr, tag);
    dmi_read(addr, actual);
    check(actual === tag, "new_tag", 64'(actual), 64'(tag));
  endtask
  task automatic sticky_blocked;
    logic [40:0] out;
    longint unsigned before_count = accepted;
    scan_dmi({7'h7e, 32'hbadd0000 | case_id, 2'b10}, out);
    jtag_in.wait_idle(10);
    check(accepted == before_count, "sticky_rejects_new_request", 64'(accepted - before_count),
          64'(0));
  endtask
  task automatic transport_profile;
    logic [40:0] out;
    logic [31:0] dtmcs, value, ignored;
    int id = 1;
    begin_case(id++, "transport_normal");
    identity();
    for (int r = 0; r < 4; r++) dmi_write(7'h10 + 7'(r), 32'h13570000 + r);
    for (int r = 0; r < 4; r++) begin
      dmi_read(7'h10 + 7'(r), value);
      check(value === 32'h13570000 + 32'(r), "normal_dmi_data", 64'(value),
            64'(32'h13570000 + 32'(r)));
    end
    end_case();
    for (int mode = 1; mode <= 2; mode++)
      for (int write_op = 0; write_op < 2; write_op++) begin
        longint unsigned a0 = accepted;
        begin_case(id++, mode == 1 ? "response_err" : "response_busy");
        endpoint_mode = mode;
        scan_dmi({7'h20, 32'hdead0000 | case_id, (write_op != 0) ? 2'b10 : 2'b01}, out);
        jtag_in.wait_idle(10);
        scan_dmi(0, out);
        check(out[1:0] === 2'(mode == 1 ? 2 : 3), "returned_dmi_status", 64'(out[1:0]),
              64'(mode == 1 ? 2 : 3));
        scan_dtmcs(0, dtmcs);
        check(dtmcs[11:10] === 2'(mode == 1 ? 2 : 3), "sticky_dtmstat", 64'(dtmcs[11:10]),
              64'(mode == 1 ? 2 : 3));
        sticky_blocked();
        endpoint_mode = 0;
        reset_sticky();
        transport_recovery();
        check(accepted - a0 == 3, "transport_case_accepts", 64'(accepted - a0), 64'(3));
        end_case();
      end
    for (int stage = 0; stage < 2; stage++)
      for (int write_op = 0; write_op < 2; write_op++) begin
        longint unsigned a0 = accepted, r0 = responses;
        time held_at;
        begin_case(id++, stage == 0 ? "busy_before_accept" : "busy_wait_response");
        hold_req  = stage == 0;
        hold_resp = stage == 1;
        scan_dmi({7'h21, 32'h12340000 | case_id, (write_op != 0) ? 2'b10 : 2'b01}, out);
        if (stage == 0) wait_request();
        else wait_count(0, a0 + 1);
        held_at = $time;
        scan_dmi(0, out);
        check(out[1:0] === 3, "early_capture_busy", 64'(out[1:0]), 64'(3));
        scan_dtmcs(0, dtmcs);
        check(dtmcs[11:10] === 3, "early_busy_sticky", 64'(dtmcs[11:10]), 64'(3));
        sticky_blocked();
        if ($time - held_at > (512 * JTAGPeriod)) control("transport_hold_exceeded_512_tck");
        @(negedge clk);
        hold_req  = 0;
        hold_resp = 0;
        wait_count(1, r0 + 1);
        scan_dtmcs(0, dtmcs);
        check(dtmcs[11:10] === 3, "busy_survives_old_completion", 64'(dtmcs[11:10]), 64'(3));
        reset_sticky();
        transport_recovery();
        check(accepted - a0 == 3, "transport_case_accepts", 64'(accepted - a0), 64'(3));
        end_case();
      end
    for (int reset_kind = 0; reset_kind < 3; reset_kind++) begin
      for (int stage = 0; stage < (reset_kind == 0 ? 2 : 1); stage++)
      for (int write_op = 0; write_op < 2; write_op++) begin
        longint unsigned a0 = accepted, r0 = responses, z0 = reset_edges;
        int old_count;
        begin_case(id++,
                   reset_kind == 0 ? "dmihardreset" : reset_kind == 1 ? "trst" : "common_reset");
        hold_req  = reset_kind == 0 && stage == 0;
        hold_resp = !hold_req;
        scan_dmi({7'h22, 32'h43210000 | case_id, (write_op != 0) ? 2'b10 : 2'b01}, out);
        if (hold_req) begin
          wait_request();
          old_count = 0;
          check(accepted == a0, "old_not_accepted", 64'(accepted - a0), 64'(0));
        end else begin
          wait_count(0, a0 + 1);
          old_count = 1;
        end
        check(responses == r0, "old_response_not_returned", 64'(responses - r0), 64'(0));
        if (reset_kind == 0) scan_dtmcs(32'h00020000, ignored);
        else if (reset_kind == 1) begin
          jtag_in.reset_master();
          jtag_in.soft_reset();
        end else begin
          @(negedge clk);
          rst_n = 0;
          jtag_mst.trst_n <= 0;
          repeat (16) @(posedge clk);
          @(negedge clk);
          rst_n = 1;
          jtag_in.reset_master();
          jtag_in.soft_reset();
        end
        for (int n = 0; n < 4096; n++) begin
          if (reset_edges > z0 && dmi_rst_n === 1 && wire_valid === 0) break;
          @(posedge clk);
          if (n == 4095) limit("reset_clear_not_observed");
        end
        @(negedge clk);
        hold_req  = 0;
        hold_resp = 0;
        @(posedge tck);
        jtag_in.wait_idle(10);
        scan_dtmcs(0, dtmcs);
        check(dtmcs === 32'h1071, "reset_dtmcs", 64'(dtmcs), 64'(32'h1071));
        transport_recovery();
        check(accepted - a0 == 64'(old_count) + 2, "reset_case_accepts", 64'(accepted - a0),
              64'(old_count + 2));
        check(responses - r0 == 2, "old_response_did_not_leak", 64'(responses - r0), 64'(2));
        end_case();
      end
    end
    check(cases == 17, "transport_case_count", 64'(cases), 64'(17));
    check(accepted == 54, "transport_request_count", 64'(accepted), 64'(54));
    check(responses == 48, "transport_response_count", 64'(responses), 64'(48));
  endtask
  task automatic boundary_profile;
    logic [40:0] out;
    logic [31:0] dtmcs;
    logic [ 6:0] addr;
    identity();
    for (int mode = 0; mode < 3; mode++)
      for (int write_op = 0; write_op < 2; write_op++)
        for (int offset = -1; offset <= 1; offset++) begin
          longint unsigned a0 = accepted, r0 = responses;
          int row = 6 * mode + 3 * write_op + (offset + 1), want_status;
          time held_at;
          begin_case(40 + row, "completion_capture_boundary");
          addr = 7'h20 + 7'(row);
          @(negedge clk);
          endpoint_mode = mode;
          hold_req = 0;
          hold_resp = 1;
          scan_dmi({addr, 32'h52340000 | case_id, (write_op != 0) ? 2'b10 : 2'b01}, out);
          wait_count(0, a0 + 1);
          held_at = $time;
          if (wire_resp_valid !== 0 || responses != r0) control("boundary_response_not_held");
          @(negedge tck);
          #1ps;
          if (wire_resp_ready !== 1) control("boundary_response_queue_not_ready");
          fork
            begin
              repeat (2) @(posedge tck);
              #1ps;
              scan_dmi(0, out);
            end
            begin
              // With 10 ns system / 50 ns TCK clocks, release at N+10/60/110 ns.
              // The passive check below verifies the consumer's actual TCK.
              repeat (1 + 5 * (offset + 1)) @(negedge clk);
              hold_resp = 0;
            end
          join
          check(last_response_edge - last_capture_edge == 64'(offset), "response_capture_offset",
                64'(last_response_edge - last_capture_edge), 64'(offset));
          // Fixed-source contract: CDC consumer at Capture-1/same/+1 TCK.
          // At same edge the existing p_fsm gives ERR precedence over Busy.
          if (offset == -1) want_status = mode == 0 ? 0 : mode == 1 ? 2 : 3;
          else if (offset == 0 && mode == 1) want_status = 2;
          else want_status = 3;
          if ($isunknown(out[1:0])) control("boundary_capture_status_unknown");
          check(out[1:0] === 2'(want_status), "boundary_capture_status", 64'(out[1:0]),
                64'(want_status));
          if (offset == -1 && mode == 0 && write_op == 0) begin
            if ($isunknown(out[33:2])) control("boundary_completed_data_unknown");
            check(out[33:2] === 32'ha5a5a5a5, "boundary_completed_read", 64'(out[33:2]),
                  64'(32'ha5a5a5a5));
          end
          scan_dtmcs(0, dtmcs);
          if ($isunknown(dtmcs)) control("boundary_dtmcs_unknown");
          check(dtmcs === (32'h1071 | (32'(want_status) << 10)), "boundary_first_sticky",
                64'(dtmcs), 64'h1071 | (64'(want_status) << 10));
          if ($time - held_at > (512 * JTAGPeriod)) control("boundary_hold_exceeded_512_tck");
          wait_count(1, r0 + 1);
          endpoint_mode = 0;
          reset_sticky();
          transport_recovery();
          check(accepted - a0 == 3, "boundary_case_accepts", 64'(accepted - a0), 64'(3));
          check(responses - r0 == 3, "boundary_case_responses", 64'(responses - r0), 64'(3));
          end_case();
        end
    check(cases == 18, "boundary_case_count", 64'(cases), 64'(18));
    check(accepted == 54, "boundary_request_count", 64'(accepted), 64'(54));
    check(responses == 54, "boundary_response_count", 64'(responses), 64'(54));
  endtask

  task automatic driver_profile;
    dm::dtm_op_status_e op;
    logic [40:0] out;
    logic [31:0] data;
    longint unsigned a0, r0;

    begin_case(60, "checked_write_success");
    a0 = accepted;
    riscv_dbg.write_dmi_status(dm::dm_csr_e'(7'h30), 32'h12345678, op);
    check(op === dm::DTM_SUCCESS, "write_completion_success", 64'(op), 64'(dm::DTM_SUCCESS));
    riscv_dbg.read_dmi(dm::dm_csr_e'(7'h30), data, 10, op);
    check(op === dm::DTM_SUCCESS && data === 32'h12345678, "checked_read_data", 64'(data),
          64'(32'h12345678));
    check(accepted - a0 == 2, "checked_access_count", 64'(accepted - a0), 64'(2));
    end_case();

    for (int mode = 1; mode <= 2; mode++) begin
      begin_case(60 + mode, "checked_write_error");
      a0 = accepted;
      endpoint_mode = mode;
      riscv_dbg.write_dmi_status(dm::dm_csr_e'(7'h31), 32'hbad, op);
      check(op === (mode == 1 ? dm::DTM_ERR : dm::DTM_BUSY), "write_completion_error", 64'(op),
            64'(mode == 1 ? dm::DTM_ERR : dm::DTM_BUSY));
      // A sticky error rejects both write and read submissions.
      riscv_dbg.write_dmi_status(dm::dm_csr_e'(7'h32), 32'hbad, op);
      check(op === (mode == 1 ? dm::DTM_ERR : dm::DTM_BUSY), "write_submission_error", 64'(op),
            64'(mode == 1 ? dm::DTM_ERR : dm::DTM_BUSY));
      riscv_dbg.read_dmi(dm::dm_csr_e'(7'h32), data, 10, op);
      check(op === (mode == 1 ? dm::DTM_ERR : dm::DTM_BUSY), "read_submission_error", 64'(op),
            64'(mode == 1 ? dm::DTM_ERR : dm::DTM_BUSY));
      check(accepted - a0 == 1, "rejected_access_count", 64'(accepted - a0), 64'(1));
      endpoint_mode = 0;
      reset_sticky();
      transport_recovery();
      end_case();
    end

    begin_case(63, "checked_write_pending_submission");
    a0 = accepted;
    r0 = responses;
    hold_resp = 1;
    scan_dmi({7'h33, 32'hfeed1234, dm::DTM_WRITE}, out);
    wait_count(0, a0 + 1);
    riscv_dbg.write_dmi_status(dm::dm_csr_e'(7'h34), 32'hbad, op);
    check(op === dm::DTM_BUSY, "pending_write_submission_busy", 64'(op), 64'(dm::DTM_BUSY));
    check(accepted - a0 == 1, "no_write_retry", 64'(accepted - a0), 64'(1));
    @(negedge clk);
    hold_resp = 0;
    wait_count(1, r0 + 1);
    check(registers[7'h33] === 32'hfeed1234 && registers[7'h34] === 32'ha5a5a5a5,
          "rejected_write_has_no_effect", 64'(registers[7'h34]), 64'(32'ha5a5a5a5));
    reset_sticky();
    transport_recovery();
    end_case();

    begin_case(64, "checked_write_delayed_completion");
    a0 = accepted;
    hold_resp = 1;
    fork
      riscv_dbg.write_dmi_status(dm::dm_csr_e'(7'h35), 32'h87654321, op, 64);
      begin
        wait_count(0, a0 + 1);
        repeat (32) @(posedge tck);
        @(negedge clk);
        hold_resp = 0;
      end
    join
    check(op === dm::DTM_SUCCESS, "delayed_write_success", 64'(op), 64'(dm::DTM_SUCCESS));
    check(accepted - a0 == 1, "delayed_write_not_repeated", 64'(accepted - a0), 64'(1));
    end_case();

    begin_case(65, "checked_write_early_completion_scan");
    a0 = accepted;
    r0 = responses;
    hold_resp = 1;
    fork
      riscv_dbg.write_dmi_status(dm::dm_csr_e'(7'h36), 32'habcdef01, op, 0);
      begin
        wait_count(0, a0 + 1);
        repeat (32) @(posedge tck);
        @(negedge clk);
        hold_resp = 0;
      end
    join
    check(op === dm::DTM_BUSY, "early_completion_busy", 64'(op), 64'(dm::DTM_BUSY));
    wait_count(1, r0 + 1);
    check(accepted - a0 == 1, "early_write_not_repeated", 64'(accepted - a0), 64'(1));
    reset_sticky();
    transport_recovery();
    end_case();
    check(accepted == 15 && responses == 15, "driver_handshake_counts", 64'(accepted),
          64'(responses));
    check(cases == 6, "driver_case_count", 64'(cases), 64'(6));
  endtask

  task automatic prepare_directed_profile(input string name);
    profile = name;
    cases = 0;
    case_id = 0;
    hold_req = 0;
    hold_resp = 0;
    endpoint_mode = 0;
    for (int a = 0; a < 128; a++) registers[a] = 32'ha5a5a5a5;
    riscv_dbg.reset_master();
    riscv_dbg.wait_idle(10);
    @(negedge clk);
    check(!stub_pending, "profile_endpoint_drained", 64'(stub_pending), 64'(0));
    accepted  = 0;
    responses = 0;
  endtask

  task automatic run_directed_tests;
    int total_cases, total_checks;
    directed_active = 1;
    enabled = 1;
    wait (rst_n);
    prepare_directed_profile("transport");
    transport_profile();
    total_cases  = cases;
    total_checks = checks;
    $display("JTAG DMI transport: cases=%0d checks=%0d errors=%0d requests=%0d responses=%0d",
             cases, checks, errors, accepted, responses);
    prepare_directed_profile("boundary");
    boundary_profile();
    total_cases += cases;
    $display("JTAG DMI boundary: cases=%0d checks=%0d errors=%0d requests=%0d responses=%0d",
             cases, checks - total_checks, errors, accepted, responses);
    total_checks = checks;
    prepare_directed_profile("driver");
    driver_profile();
    total_cases += cases;
    $display("JTAG DMI driver: cases=%0d checks=%0d errors=%0d requests=%0d responses=%0d", cases,
             checks - total_checks, errors, accepted, responses);
    // Drain the final response before changing endpoint ownership.
    riscv_dbg.wait_idle(10);
    check(!stub_pending, "directed_endpoint_drained", 64'(stub_pending), 64'(0));
    if (errors != 0) $fatal(1, "JTAG DMI directed FAIL: %0d errors.", errors);
    $display("JTAG DMI directed PASS: %0d cases, %0d checks.", total_cases, checks);
    enabled = 0;
    directed_active = 0;
  endtask

  mailbox #(dmi_test::req_t) req_mbx = new;
  mailbox #(logic [31:0]) rsp_mbx = new;
  localparam int unsigned NrRandomTransactions = 2_000;
  int unsigned nr_transactions = 0;

  initial begin
    logic [31:0] idcode;
    dm::dtmcs_t dtmcs;
    logic [4:0] opocode;
    start_rand = 0;
    if (!$value$plusargs("JTAG_DMI_TEST=%s", test_mode)) test_mode = "all";
    if (!(test_mode inside {"all", "directed", "random"}))
      $fatal(1, "Unknown JTAG DMI test mode: %s.", test_mode);
    if (test_mode != "random") begin
      run_directed_tests();
      if (test_mode == "directed") $finish;
    end
    directed_done = 1;
    wait (random_ready);

    $display("Resetting");
    riscv_dbg.reset_master();

    /// Test ID Code.
    $display("Reading ID Code");
    riscv_dbg.get_idcode(idcode);

    $display("Got ID Code %h", idcode);

    // Check ID Code.
`ifdef TARGET_BSCANE
    assert (idcode == i_jtag_sime2.IDCODEval_sig);
`else
    assert (idcode == IDCode);
`endif

    /// Test DTMCs
    riscv_dbg.read_dtmcs(dtmcs);
    $display("DTMCS: %p", dtmcs);
    assert (dtmcs.version == 1);
    assert (dtmcs.abits == 7);

    riscv_dbg.write_dtmcs(32'hdeadbeef);

    riscv_dbg.read_dtmcs(dtmcs);
    $display("DTMCS: %p", dtmcs);
    assert (dtmcs.version == 1);
    assert (dtmcs.abits == 7);

    /// Random DMI transactions.
    // Generate a number of random transactions and drive them on the JTAG
    // interface.
    start_rand = 1;
    for (int i = 0; i < NrRandomTransactions; i++) begin
      automatic dmi_test::req_t transaction = new;
      assert (transaction.randomize() with {op inside {dm::DTM_WRITE, dm::DTM_READ};} == 1);
      if (transaction.op == dm::DTM_WRITE) begin
        riscv_dbg.write_dmi(dm::dm_csr_e'(transaction.addr), transaction.data);
        req_mbx.put(transaction);
        rsp_mbx.put('h0);
      end else if (transaction.op == dm::DTM_READ) begin
        automatic logic [31:0] rdata;
        automatic dm::dtm_op_status_e op_status;
        riscv_dbg.read_dmi(dm::dm_csr_e'(transaction.addr), rdata, 10, op_status);
        assert (op_status == dm::DTM_SUCCESS)
        else $error("Unexpected DMI read status: %0d.", op_status);
        req_mbx.put(transaction);
        rsp_mbx.put(rdata);
      end
      // Randomly reset the dmi using either hard jtag trst_ni, JTAG
      // TestLogicReset or the dtmcs.dmihardreset bit.
      if ($urandom_range(0, 100) < 5) begin
        riscv_dbg.wait_idle(30);
        case ($urandom_range(
            0, 3
        ))
          0: begin
            $info("Resetting JTAG DMI using asynchronous JTAG reset signal...");
            riscv_dbg.reset_master();
          end

          1: begin
            $info("Resetting JTAG DMI using JTAG softreset (TestLogicReset TAP state).");
            riscv_dbg.jtag.soft_reset();
          end

          2: begin
            dm::dtmcs_t dtmcs_value;
            dtmcs_value = '0;
            dtmcs_value.dmihardreset = 1;
            $info("Resetting JTAG DMI using DMI dtmcs registers' dmihardreset control bit.");
            riscv_dbg.write_dtmcs(dtmcs_value);
          end

          default: ;
        endcase
      end
    end
    wait (nr_transactions == NrRandomTransactions);
    $display("JTAG DMI random PASS: %0d transactions.", nr_transactions);
    $finish();
  end

  // ----------
  // Scoreboard
  // ----------
  initial begin
    forever begin
      automatic dmi_test::req_t req, req_mon;
      automatic dmi_test::rsp_t rsp_mon;
      automatic logic [31:0] rsp;

      dmi_monitor.req_mbx.get(req_mon);
      dmi_monitor.rsp_mbx.get(rsp_mon);
      req_mbx.get(req);
      rsp_mbx.get(rsp);
      nr_transactions++;
      assert (req.addr == req_mon.addr)
      else $error("Invalid dmi request. Got address %0x instead of %0x.", req_mon.addr, req.addr);
      assert (req.op == req_mon.op)
      else $error("Invalid dmi request. Got op %0x instead of %0x.", req_mon.op, req.op);
      if (req.op == dm::DTM_READ) begin
        assert (rsp_mon.data == rsp)
        else $error("Invalid DMI read response. Got %08x instead of %08x.", rsp, rsp_mon.data);
      end else begin
        assert (req.data == req_mon.data);
      end
    end
  end

  final begin
    assert (test_mode == "directed" || NrRandomTransactions == nr_transactions)
    else $error("Remaining transactions.");
  end

  initial begin
    #50ms;
    $fatal(1, "JTAG DMI regression timed out.");
  end

endmodule
