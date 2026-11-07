// Copyright 2026 CheshireAra contributors.
// SPDX-License-Identifier: Apache-2.0
// Real DTM/TAP/CDC with a scripted public DMI endpoint.
`timescale 1ns/1ps
module tb_dmi_capture;
 localparam string Scope="unit";
 localparam logic[31:0] Idcode=32'h00000db3;
 logic sys_clk=0,tck=0,rst_n=0;
 always #2.5ns sys_clk=~sys_clk;
 always #10ns tck=~tck;
 JTAG_DV jtag(tck);
 string profile="transport";
 int unsigned case_id=0,errors=0,checks=0,cases=0,epoch=0;
 bit stopped=0; time case_started=0;
 longint unsigned cycle=0,accepted=0,responses=0,reset_edges=0;
 logic old_dmi_rst=0;
 bit enabled=0,hold_req=0,hold_resp=0;
 int endpoint_mode=0;
 dm::dmi_req_t wire_req;
 dm::dmi_resp_t wire_resp,stub_resp;
 logic wire_valid,wire_ready,wire_resp_valid,wire_resp_ready,dmi_rst_n;
 logic stub_pending=0;
 logic [31:0] registers[128];
 assign wire_ready=!hold_req && !stub_pending && dmi_rst_n;
 assign wire_resp_valid=stub_pending && !hold_resp && dmi_rst_n;
 assign wire_resp=stub_resp;
 dmi_jtag #(.IdcodeValue(Idcode)) dtm(.clk_i(sys_clk),.rst_ni(rst_n),.testmode_i(1'b0),
  .dmi_rst_no(dmi_rst_n),.dmi_req_o(wire_req),.dmi_req_valid_o(wire_valid),.dmi_req_ready_i(wire_ready),
  .dmi_resp_i(wire_resp),.dmi_resp_ready_o(wire_resp_ready),.dmi_resp_valid_i(wire_resp_valid),
  .tck_i(tck),.tms_i(jtag.tms),.trst_ni(jtag.trst_n),.td_i(jtag.tdi),.td_o(jtag.tdo),.tdo_oe_o());
 always @(posedge sys_clk)begin
  cycle++;
  if(case_id!=0 && !stopped && $time-case_started>=1ms)begin
   stopped=1;$display("[E_DEBUG_WAIT_LIMIT] scope=%s profile=%s case=%0d epoch=%0d cycle=%0d time_ps=%0.0f label=case_deadline",Scope,profile,case_id,epoch,cycle,$realtime*1000.0);
  end
  if(!rst_n || !dmi_rst_n)stub_pending<=0;
  else begin
   if(wire_resp_valid && wire_resp_ready)stub_pending<=0;
   if(wire_valid && wire_ready)begin
    stub_pending<=1;
    stub_resp.resp<=endpoint_mode==1?dm::DTM_ERR:endpoint_mode==2?dm::DTM_BUSY:dm::DTM_SUCCESS;
    stub_resp.data<=registers[wire_req.addr];
    if(endpoint_mode==0 && wire_req.op==dm::DTM_WRITE)registers[wire_req.addr]=wire_req.data;
   end
  end
  if(enabled)begin
   if(old_dmi_rst===1 && dmi_rst_n===0)reset_edges++;
   old_dmi_rst=dmi_rst_n;
   if(rst_n&&dmi_rst_n&&wire_valid&&wire_ready)accepted++;
   if(rst_n&&dmi_rst_n&&wire_resp_valid&&wire_resp_ready)responses++;
   if((wire_valid&&wire_ready)||(wire_resp_valid&&wire_resp_ready))
    $display("DMI_HANDSHAKE profile=%s case=%0d req=%b rsp=%b addr=%h op=%h data=%h resp=%h",profile,case_id,wire_valid&&wire_ready,wire_resp_valid&&wire_resp_ready,wire_req.addr,wire_req.op,wire_resp.data,wire_resp.resp);
  end
 end
 bit dmi_held=0;
 dm::dmi_req_t held_dmi;
 always @(posedge sys_clk)if(enabled)begin
  logic sampled_valid,sampled_ready;
  dm::dmi_req_t sampled_req;
  sampled_valid=wire_valid;sampled_ready=wire_ready;sampled_req=wire_req;
  #1ps;
  if(!rst_n||!dmi_rst_n)dmi_held=0;
  else begin
   if(dmi_held)check(sampled_valid===1 && sampled_req===held_dmi,"dmi_request_hold",sampled_req,held_dmi);
   dmi_held=sampled_valid===1 && sampled_ready!==1;held_dmi=sampled_req;
  end
 end
 typedef jtag_test::jtag_driver #(.IrLength(5),.TA(2ns),.TT(18ns)) jdrv_t;
 jdrv_t jdrv;
 task automatic fail(input string label,input logic[63:0] actual,input logic[63:0] expected);
   errors++;$display("[E_DEBUG_ERROR] scope=%s profile=%s case=%0d epoch=%0d cycle=%0d time_ps=%0.0f label=%s actual=%h expected=%h",Scope,profile,case_id,epoch,cycle,$realtime*1000.0,label,actual,expected);
 endtask
 task automatic check(input bit good,input string label,input logic[63:0] actual,input logic[63:0] expected);
   checks++;if(!good)fail(label,actual,expected);
 endtask
 task automatic limit(input string label);
   stopped=1;$display("[E_DEBUG_WAIT_LIMIT] scope=%s profile=%s case=%0d epoch=%0d cycle=%0d time_ps=%0.0f label=%s",Scope,profile,case_id,epoch,cycle,$realtime*1000.0,label);forever@(posedge sys_clk);
 endtask
 task automatic control(input string label);
   stopped=1;$display("[E_DEBUG_CONTROL_ERROR] scope=%s profile=%s case=%0d epoch=%0d cycle=%0d time_ps=%0.0f label=%s",Scope,profile,case_id,epoch,cycle,$realtime*1000.0,label);forever@(posedge sys_clk);
 endtask
 task automatic begin_case(input int id,input string kind);
   if(stopped)forever@(posedge sys_clk);case_id=id;cases++;case_started=$time;
   $display("[E_DEBUG_CASE] event=begin scope=%s profile=%s case=%0d epoch=%0d cycle=%0d time_ps=%0.0f kind=%s",Scope,profile,case_id,epoch,cycle,$realtime*1000.0,kind);
 endtask
 task automatic end_case;
   if(stopped)forever@(posedge sys_clk);
   $display("[E_DEBUG_CASE] event=end scope=%s profile=%s case=%0d epoch=%0d cycle=%0d time_ps=%0.0f errors=%0d",Scope,profile,case_id,epoch,cycle,$realtime*1000.0,errors);
   case_id=0;
 endtask
 task automatic scan_dmi(input logic[40:0] request,output logic[40:0] response);
   logic tx[$],rx[$];
   if(stopped)forever@(posedge sys_clk);
   @(posedge tck);for(int b=0;b<41;b++)tx.push_back(request[b]);
   jdrv.set_ir(5'h11);jdrv.shift_dr();jdrv.readwrite_bits(rx,tx,1'b1);jdrv.update_dr(1'b0);
   response='x;for(int b=0;b<41;b++)response[b]=rx[b];
   $display("[E_DEBUG_SCAN] scope=%s profile=%s case=%0d epoch=%0d cycle=%0d time_ps=%0.0f width=41 request=%h response=%h",Scope,profile,case_id,epoch,cycle,$realtime*1000.0,request,response);
 endtask
 task automatic scan_dtmcs(input logic[31:0] request,output logic[31:0] response);
   logic tx[$],rx[$];if(stopped)forever@(posedge sys_clk);@(posedge tck);for(int b=0;b<32;b++)tx.push_back(request[b]);
   jdrv.set_ir(5'h10);jdrv.shift_dr();jdrv.readwrite_bits(rx,tx,1'b1);jdrv.update_dr(1'b0);
   response='x;for(int b=0;b<32;b++)response[b]=rx[b];
   $display("[E_DEBUG_SCAN] scope=%s profile=%s case=%0d epoch=%0d cycle=%0d time_ps=%0.0f width=32 ir=10 request=%h response=%h",Scope,profile,case_id,epoch,cycle,$realtime*1000.0,request,response);
 endtask
 task automatic identity;
   logic tx[$],rx[$];logic[31:0] value,dtmcs;
   @(posedge tck);for(int b=0;b<32;b++)tx.push_back(0);
   jdrv.set_ir(5'h01);jdrv.shift_dr();jdrv.readwrite_bits(rx,tx,1'b1);jdrv.update_dr(1'b0);
   for(int b=0;b<32;b++)value[b]=rx[b];check(value===Idcode,"idcode",value,Idcode);
   scan_dtmcs(0,dtmcs);check(dtmcs===32'h00001071,"dtmcs_identity",dtmcs,32'h1071);
 endtask
 task automatic dmi_write(input logic[6:0] addr,input logic[31:0] value);
   logic[40:0] ignored,response;
   scan_dmi({addr,value,2'b10},ignored);jdrv.wait_idle(10);scan_dmi(41'd0,response);
   check(response[1:0]===0,"dmi_write_status",response[1:0],0);
 endtask
 task automatic dmi_read(input logic[6:0] addr,output logic[31:0] value);
   logic[40:0] ignored,response;
   scan_dmi({addr,32'd0,2'b01},ignored);jdrv.wait_idle(10);scan_dmi(41'd0,response);
   check(response[1:0]===0,"dmi_read_status",response[1:0],0);value=response[33:2];
 endtask
 task automatic wait_count(input bit response_counter,input longint unsigned wanted);
   for(int n=0;n<4096;n++)begin
     if((response_counter?responses:accepted)>=wanted)return;
     @(posedge sys_clk);
   end
   limit("transport_handshake");
 endtask
 task automatic wait_request;
   for(int n=0;n<4096;n++)begin if(wire_valid===1)return;@(posedge sys_clk);end
   limit("transport_request_valid");
 endtask
 task automatic reset_sticky;
   logic[31:0] ignored,actual;
   scan_dtmcs(32'h00010000,ignored);jdrv.wait_idle(10);scan_dtmcs(0,actual);
   check(actual===32'h1071,"dtmcs_after_dmireset",actual,32'h1071);
 endtask
 task automatic transport_recovery;
   logic[31:0] actual,tag;logic[6:0] addr;
   addr=7'h40+7'(case_id);tag=32'h69a50000|case_id;
   dmi_write(addr,tag);dmi_read(addr,actual);check(actual===tag,"new_tag",actual,tag);
 endtask
 task automatic sticky_blocked;
   logic[40:0] out;longint unsigned before_count=accepted;
   scan_dmi({7'h7e,32'hbadd0000|case_id,2'b10},out);jdrv.wait_idle(10);
   check(accepted==before_count,"sticky_rejects_new_request",accepted-before_count,0);
 endtask
 task automatic transport_profile;
   logic[40:0] out;logic[31:0] dtmcs,value,ignored;
   int id=1;
   begin_case(id++,"transport_normal");identity();
   for(int r=0;r<4;r++)dmi_write(7'h10+7'(r),32'h13570000+r);
   for(int r=0;r<4;r++)begin dmi_read(7'h10+7'(r),value);check(value===32'h13570000+32'(r),"normal_dmi_data",value,32'h13570000+32'(r));end
   end_case();
   for(int mode=1;mode<=2;mode++)for(int write_op=0;write_op<2;write_op++)begin
     longint unsigned a0=accepted;
     begin_case(id++,mode==1?"response_err":"response_busy");endpoint_mode=mode;
     scan_dmi({7'h20,32'hdead0000|case_id,write_op?2'b10:2'b01},out);jdrv.wait_idle(10);scan_dmi(0,out);
     check(out[1:0]===2'(mode==1?2:3),"returned_dmi_status",out[1:0],mode==1?2:3);
     scan_dtmcs(0,dtmcs);check(dtmcs[11:10]===2'(mode==1?2:3),"sticky_dtmstat",dtmcs[11:10],mode==1?2:3);
     sticky_blocked();endpoint_mode=0;reset_sticky();transport_recovery();
     check(accepted-a0==3,"transport_case_accepts",accepted-a0,3);end_case();
   end
   for(int stage=0;stage<2;stage++)for(int write_op=0;write_op<2;write_op++)begin
     longint unsigned a0=accepted,r0=responses;time held_at;
     begin_case(id++,stage==0?"busy_before_accept":"busy_wait_response");
     hold_req=stage==0;hold_resp=stage==1;
     scan_dmi({7'h21,32'h12340000|case_id,write_op?2'b10:2'b01},out);
     if(stage==0)wait_request();else wait_count(0,a0+1);held_at=$time;
     scan_dmi(0,out);check(out[1:0]===3,"early_capture_busy",out[1:0],3);
     scan_dtmcs(0,dtmcs);check(dtmcs[11:10]===3,"early_busy_sticky",dtmcs[11:10],3);sticky_blocked();
     if($time-held_at>10240ns)control("transport_hold_exceeded_512_tck");
     @(negedge sys_clk);hold_req=0;hold_resp=0;wait_count(1,r0+1);scan_dtmcs(0,dtmcs);check(dtmcs[11:10]===3,"busy_survives_old_completion",dtmcs[11:10],3);
     reset_sticky();transport_recovery();check(accepted-a0==3,"transport_case_accepts",accepted-a0,3);end_case();
   end
   for(int reset_kind=0;reset_kind<3;reset_kind++)begin
     for(int stage=0;stage<(reset_kind==0?2:1);stage++)for(int write_op=0;write_op<2;write_op++)begin
       longint unsigned a0=accepted,r0=responses,z0=reset_edges;int old_count;
       begin_case(id++,reset_kind==0?"dmihardreset":reset_kind==1?"trst":"common_reset");
       hold_req=reset_kind==0 && stage==0;hold_resp=!hold_req;
       scan_dmi({7'h22,32'h43210000|case_id,write_op?2'b10:2'b01},out);
       if(hold_req)begin wait_request();old_count=0;check(accepted==a0,"old_not_accepted",accepted-a0,0);end
       else begin wait_count(0,a0+1);old_count=1;end
       check(responses==r0,"old_response_not_returned",responses-r0,0);
       $display("[E_DEBUG_ABORT] scope=%s profile=%s case=%0d epoch=%0d cycle=%0d time_ps=%0.0f accepted=%0d returned=%0d reset_kind=%0d",Scope,profile,case_id,epoch,cycle,$realtime*1000.0,accepted-a0,responses-r0,reset_kind);
       epoch++;
       if(reset_kind==0)scan_dtmcs(32'h00020000,ignored);
       else if(reset_kind==1)begin jdrv.reset_master();jdrv.soft_reset();end
       else begin
         @(negedge sys_clk);rst_n=0;jtag.trst_n<=0;repeat(16)@(posedge sys_clk);@(negedge sys_clk);rst_n=1;
         jdrv.reset_master();jdrv.soft_reset();
       end
       for(int n=0;n<4096;n++)begin if(reset_edges>z0 && dmi_rst_n===1 && wire_valid===0)break;@(posedge sys_clk);if(n==4095)limit("reset_clear_not_observed");end
       @(negedge sys_clk);hold_req=0;hold_resp=0;@(posedge tck);jdrv.wait_idle(10);scan_dtmcs(0,dtmcs);check(dtmcs===32'h1071,"reset_dtmcs",dtmcs,32'h1071);
       transport_recovery();check(accepted-a0==old_count+2,"reset_case_accepts",accepted-a0,old_count+2);
       check(responses-r0==2,"old_response_did_not_leak",responses-r0,2);end_case();
     end
   end
   check(cases==17,"transport_case_count",cases,17);check(accepted==54,"transport_request_count",accepted,54);
 endtask
 task automatic boundary_profile;
   logic[40:0] out;logic[31:0] dtmcs;logic[6:0] addr;
   identity();
   for(int mode=0;mode<3;mode++)for(int write_op=0;write_op<2;write_op++)for(int offset=-1;offset<=1;offset++)begin
     longint unsigned a0=accepted,r0=responses;
     int row=6*mode+3*write_op+(offset+1),want_status;
     time held_at;
     begin_case(40+row,"completion_capture_boundary");addr=7'h20+7'(row);
     @(negedge sys_clk);endpoint_mode=mode;hold_req=0;hold_resp=1;
     scan_dmi({addr,32'h52340000|case_id,write_op?2'b10:2'b01},out);
     wait_count(0,a0+1);held_at=$time;
     if(wire_resp_valid!==0 || responses!=r0)control("boundary_response_not_held");
     @(negedge tck);#1ps;
     if(wire_resp_ready!==1)control("boundary_response_queue_not_ready");
     fork
       begin
         repeat(2)@(posedge tck);#1ps;scan_dmi(0,out);
       end
       begin
         // From this real TCK falling edge N: release at N+5/25/45ns.
         repeat(1+4*(offset+1))@(negedge sys_clk);
         hold_resp=0;
       end
     join
     // Fixed-source contract: CDC consumer at Capture-1/same/+1 TCK.
     // At same edge the existing p_fsm gives ERR precedence over Busy.
     if(offset==-1)want_status=mode==0?0:mode==1?2:3;
     else if(offset==0 && mode==1)want_status=2;
     else want_status=3;
     if($isunknown(out[1:0]))control("boundary_capture_status_unknown");
     check(out[1:0]===2'(want_status),"boundary_capture_status",out[1:0],want_status);
     if(offset==-1 && mode==0 && write_op==0)begin
       if($isunknown(out[33:2]))control("boundary_completed_data_unknown");
       check(out[33:2]===32'ha5a5a5a5,"boundary_completed_read",out[33:2],32'ha5a5a5a5);
     end
     scan_dtmcs(0,dtmcs);
     if($isunknown(dtmcs))control("boundary_dtmcs_unknown");
     check(dtmcs===(32'h1071|(32'(want_status)<<10)),"boundary_first_sticky",dtmcs,32'h1071|(32'(want_status)<<10));
     if($time-held_at>10240ns)control("boundary_hold_exceeded_512_tck");
     wait_count(1,r0+1);endpoint_mode=0;reset_sticky();transport_recovery();
     check(accepted-a0==3,"boundary_case_accepts",accepted-a0,3);
     check(responses-r0==3,"boundary_case_responses",responses-r0,3);end_case();
   end
   check(cases==18,"boundary_case_count",cases,18);
   check(accepted==54,"boundary_request_count",accepted,54);
   check(responses==54,"boundary_response_count",responses,54);
 endtask
 initial begin
   if(!$value$plusargs("E_DEBUG_PROFILE=%s",profile))profile="transport";
   if(!(profile inside {"transport","boundary"}))control("unsupported_profile");
   for(int a=0;a<128;a++)registers[a]=32'ha5a5a5a5;
   jtag.tms=1'b1;jtag.tdi=1'b0;jtag.trst_n=1'b0;
   jdrv=new(jtag);enabled=1;
   $display("[E_DEBUG_META] schema=1 scope=unit profile=%s clock_ps=5000 tck_ps=20000 ir_bits=5 dr_bits=41",profile);
   repeat(16)@(posedge sys_clk);@(negedge sys_clk);rst_n=1;
   jdrv.reset_master();jdrv.soft_reset();jdrv.wait_idle(10);
   if(profile=="transport")transport_profile();else boundary_profile();
   repeat(32)@(posedge sys_clk);
   $display("[E_DEBUG_DONE] scope=unit profile=%s cases=%0d checks=%0d errors=%0d dmi_requests=%0d dmi_responses=%0d sba_requests=0",profile,cases,checks,errors,accepted,responses);$finish;
 end
 initial begin #10000000ns;$display("[E_DEBUG_HDL_LIMIT] scope=unit profile=%s case=%0d epoch=%0d cycle=%0d errors=%0d",profile,case_id,epoch,cycle,errors);$finish;end
endmodule
