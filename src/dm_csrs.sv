/* Copyright 2018 ETH Zurich and University of Bologna.
 * Copyright and related rights are licensed under the Solderpad Hardware
 * License, Version 0.51 (the “License”); you may not use this file except in
 * compliance with the License.  You may obtain a copy of the License at
 * http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
 * or agreed to in writing, software, hardware and materials distributed under
 * this License is distributed on an “AS IS” BASIS, WITHOUT WARRANTIES OR
 * CONDITIONS OF ANY KIND, either express or implied. See the License for the
 * specific language governing permissions and limitations under the License.
 *
 * File:  dm_csrs.sv
 * Author: Florian Zaruba <zarubaf@iis.ee.ethz.ch>
 * Date:   30.6.2018
 *
 * Description: Debug CSRs. Communication over Debug Transport Module (DTM)
 */

module dm_csrs #(
    parameter int                 NrHarts          = -1,
    parameter int                 BusWidth         = -1,
    parameter logic [NrHarts-1:0] Selectable_Harts = -1
) (
    input  logic                              clk_i,              // Clock
    input  logic                              rst_ni,             // Asynchronous reset active low
    input  logic                              testmode_i,
    input  logic                              dmi_rst_ni,         // Debug Module Interface reset, active-low
    input  logic                              dmi_req_valid_i,
    output logic                              dmi_req_ready_o,
    input  dm::dmi_req_t                      dmi_req_i,
    // every request needs a response one cycle later
    output logic                              dmi_resp_valid_o,
    input  logic                              dmi_resp_ready_i,
    output dm::dmi_resp_t                     dmi_resp_o,
    // global ctrl
    output logic                              ndmreset_o,      // non-debug module reset, active-high
    output logic                              dmactive_o,      // 1 -> debug-module is active, 0 -> synchronous re-set
    // hart status
    input  dm::hartinfo_t [NrHarts-1:0]       hartinfo_i,      // static hartinfo
    input  logic [NrHarts-1:0]                halted_i,        // hart is halted
    input  logic [NrHarts-1:0]                unavailable_i,   // e.g.: powered down
    input  logic [NrHarts-1:0]                resumeack_i,     // hart acknowledged resume request
    // hart control
    output logic [19:0]                       hartsel_o,       // hartselect to ctrl module
    output logic [NrHarts-1:0]                haltreq_o,       // request to halt a hart
    output logic [NrHarts-1:0]                resumereq_o,     // request hart to resume

    output logic                              cmd_valid_o,       // debugger is writing to the command field
    output dm::command_t                      cmd_o,             // abstract command
    input  logic                              cmderror_valid_i,  // an error occured
    input  dm::cmderr_t                       cmderror_i,        // this error occured
    input  logic                              cmdbusy_i,         // cmd is currently busy executing

    output logic [dm::ProgBufSize-1:0][31:0]  progbuf_o, // to system bus
    output logic [dm::DataCount-1:0][31:0]    data_o,

    input  logic [dm::DataCount-1:0][31:0]    data_i,
    input  logic                              data_valid_i,
    // system bus access module (SBA)
    output logic [BusWidth-1:0]               sbaddress_o,
    input  logic [BusWidth-1:0]               sbaddress_i,
    output logic                              sbaddress_write_valid_o,
    // control signals in
    output logic                              sbreadonaddr_o,
    output logic                              sbautoincrement_o,
    output logic [2:0]                        sbaccess_o,
    // data out
    output logic                              sbreadondata_o,
    output logic [BusWidth-1:0]               sbdata_o,
    output logic                              sbdata_read_valid_o,
    output logic                              sbdata_write_valid_o,
    // read data in
    input  logic [BusWidth-1:0]               sbdata_i,
    input  logic                              sbdata_valid_i,
    // control signals
    input  logic                              sbbusy_i,
    input  logic                              sberror_valid_i, // bus error occurred
    input  logic [2:0]                        sberror_i // bus error occurred
);
    // the amount of bits we need to represent all harts
    localparam HartSelLen = (NrHarts == 1) ? 1 : $clog2(NrHarts);
    dm::dtm_op_t dtm_op;
    assign dtm_op = dm::dtm_op_t'(dmi_req_i.op);

    logic        resp_queue_full;
    logic        resp_queue_empty;
    logic        resp_queue_push;
    logic        resp_queue_pop;
    logic [31:0] resp_queue_data;

    localparam dm::dm_csr_t DataEnd = dm::dm_csr_t'((dm::Data0 + {4'b0, dm::DataCount}));
    localparam dm::dm_csr_t ProgBufEnd = dm::dm_csr_t'((dm::ProgBuf0 + {4'b0, dm::ProgBufSize}));

    logic [31:0] haltsum0, haltsum1, haltsum2, haltsum3;
    logic [NrHarts/2**5 :0][31:0] halted_reshaped0;
    logic [NrHarts/2**10:0][31:0] halted_reshaped1;
    logic [NrHarts/2**15:0][31:0] halted_reshaped2;
    logic [(NrHarts/2**10+1)*32-1:0] halted_flat1;
    logic [(NrHarts/2**15+1)*32-1:0] halted_flat2;
    logic [32-1:0] halted_flat3;

    // haltsum0
    assign halted_reshaped0 = halted_i;
    assign haltsum0         = halted_reshaped0[hartsel_o[19:5]];
    // haltsum1
    always_comb begin : p_reduction1
      halted_flat1 = '1;
      for (int k=0; k<NrHarts/2**5; k++) begin
        halted_flat1[k] = &halted_reshaped0[k];
      end
      halted_reshaped1 = halted_flat1;
      haltsum1         = halted_reshaped1[hartsel_o[19:10]];
    end
    // haltsum2
    always_comb begin : p_reduction2
      halted_flat2 = '1;
      for (int k=0; k<NrHarts/2**10; k++) begin
        halted_flat2[k] = &halted_reshaped1[k];
      end
      halted_reshaped2 = halted_flat2;
      haltsum2         = halted_reshaped2[hartsel_o[19:15]];
    end
    // haltsum3
    always_comb begin : p_reduction3
      halted_flat3 = '1;
      for (int k=0; k<NrHarts/2**15; k++) begin
        halted_flat3[k] = &halted_reshaped2[k];
      end
      haltsum3 = halted_flat3;
    end


    dm::dmstatus_t      dmstatus;
    dm::dmcontrol_t     dmcontrol_d, dmcontrol_q;
    dm::abstractcs_t    abstractcs;
    dm::cmderr_t        cmderr_d, cmderr_q;
    dm::command_t       command_d, command_q;
    dm::abstractauto_t  abstractauto_d, abstractauto_q;
    dm::sbcs_t          sbcs_d, sbcs_q;
    logic [63:0]        sbaddr_d, sbaddr_q;
    logic [63:0]        sbdata_d, sbdata_q;

    logic [NrHarts-1:0] havereset_d, havereset_q;
    // program buffer
    logic [dm::ProgBufSize-1:0][31:0] progbuf_d, progbuf_q;
    // because first data address starts at 0x04
    logic [({3'b0, dm::DataCount} + dm::Data0 - 1):(dm::Data0)][31:0] data_d, data_q;

    logic [HartSelLen-1:0] selected_hart;

    // a successful response returns zero
    assign dmi_resp_o.resp = dm::DTM_SUCCESS;
    assign dmi_resp_valid_o     = ~resp_queue_empty;
    assign dmi_req_ready_o      = ~resp_queue_full;
    assign resp_queue_push      = dmi_req_valid_i & dmi_req_ready_o;
    // SBA
    assign sbautoincrement_o = sbcs_q.sbautoincrement;
    assign sbreadonaddr_o    = sbcs_q.sbreadonaddr;
    assign sbreadondata_o    = sbcs_q.sbreadondata;
    assign sbaccess_o        = sbcs_q.sbaccess;
    assign sbdata_o          = sbdata_q;
    assign sbaddress_o       = sbaddr_q;

    assign hartsel_o         = {dmcontrol_q.hartselhi, dmcontrol_q.hartsello};

    always_comb begin : csr_read_write
        // --------------------
        // Static Values (R/O)
        // --------------------
        // dmstatus
        dmstatus    = '0;
        dmstatus.version = dm::DbgVersion013;
        // no authentication implemented
        dmstatus.authenticated = 1'b1;
        // we do not support halt-on-reset sequence
        dmstatus.hasresethaltreq = 1'b0;
        // TODO(zarubaf) things need to change here if we implement the array mask
        dmstatus.allhavereset = havereset_q[selected_hart];
        dmstatus.anyhavereset = havereset_q[selected_hart];

        dmstatus.allresumeack = resumeack_i[selected_hart];
        dmstatus.anyresumeack = resumeack_i[selected_hart];

        dmstatus.allunavail   = unavailable_i[selected_hart];
        dmstatus.anyunavail   = unavailable_i[selected_hart];

        // as soon as we are out of the legal Hart region tell the debugger
        // that there are only non-existent harts
        dmstatus.allnonexistent = (hartsel_o > NrHarts[19:0] - 1) ? 1'b1 : 1'b0;
        dmstatus.anynonexistent = (hartsel_o > NrHarts[19:0] - 1) ? 1'b1 : 1'b0;

        dmstatus.allhalted    = halted_i[selected_hart];
        dmstatus.anyhalted    = halted_i[selected_hart];

        dmstatus.allrunning   = ~halted_i[selected_hart];
        dmstatus.anyrunning   = ~halted_i[selected_hart];

        // abstractcs
        abstractcs = '0;
        abstractcs.datacount = dm::DataCount;
        abstractcs.progbufsize = dm::ProgBufSize;
        abstractcs.busy = cmdbusy_i;
        abstractcs.cmderr = cmderr_q;

        // abstractautoexec
        abstractauto_d = abstractauto_q;
        abstractauto_d.zero0 = '0;

        // default assignments
        havereset_d = havereset_q;
        dmcontrol_d = dmcontrol_q;
        cmderr_d    = cmderr_q;
        command_d   = command_q;
        progbuf_d   = progbuf_q;
        data_d      = data_q;
        sbcs_d      = sbcs_q;
        sbaddr_d    = sbaddress_i;
        sbdata_d    = sbdata_q;

        resp_queue_data         = 32'b0;
        cmd_valid_o             = 1'b0;
        sbaddress_write_valid_o = 1'b0;
        sbdata_read_valid_o     = 1'b0;
        sbdata_write_valid_o    = 1'b0;

        // reads
        if (dmi_req_ready_o && dmi_req_valid_i && dtm_op == dm::DTM_READ) begin
            unique case ({1'b0, dmi_req_i.addr}) inside
                [(dm::Data0):DataEnd]: begin
                    if (dm::DataCount > 0) begin
                        resp_queue_data = data_q[dmi_req_i.addr[4:0]];
                    end
                    if (!cmdbusy_i) begin
                        // check whether we need to re-execute the command (just give a cmd_valid)
                        cmd_valid_o = abstractauto_q.autoexecdata[dmi_req_i.addr[3:0] - int'(dm::Data0)];
                    end
                end
                dm::DMControl:    resp_queue_data = dmcontrol_q;
                dm::DMStatus:     resp_queue_data = dmstatus;
                dm::Hartinfo:     resp_queue_data = hartinfo_i[selected_hart];
                dm::AbstractCS:   resp_queue_data = abstractcs;
                dm::AbstractAuto: resp_queue_data = abstractauto_q;
                // command is read-only
                dm::Command:    resp_queue_data = '0;
                [(dm::ProgBuf0):ProgBufEnd]: begin
                    resp_queue_data = progbuf_q[dmi_req_i.addr[4:0]];
                    if (!cmdbusy_i) begin
                        // check whether we need to re-execute the command (just give a cmd_valid)
                        // TODO(zarubaf): check if offset is correct - without it this may assign Xes
                        cmd_valid_o = abstractauto_q.autoexecprogbuf[dmi_req_i.addr[3:0]+16];
                    end
                end
                dm::HaltSum0: resp_queue_data = haltsum0;
                dm::HaltSum1: resp_queue_data = haltsum1;
                dm::HaltSum2: resp_queue_data = haltsum2;
                dm::HaltSum3: resp_queue_data = haltsum3;
                dm::SBCS: begin
                    resp_queue_data = sbcs_q;
                end
                dm::SBAddress0: begin
                    // access while the SBA was busy
                    if (sbbusy_i) begin
                       sbcs_d.sbbusyerror = 1'b1;
                    end begin
                        resp_queue_data = sbaddr_q[31:0];
                    end
                end
                dm::SBAddress1: begin
                    // access while the SBA was busy
                    if (sbbusy_i) begin
                       sbcs_d.sbbusyerror = 1'b1;
                    end begin
                        resp_queue_data = sbaddr_q[63:32];
                    end
                end
                dm::SBData0: begin
                    // access while the SBA was busy
                    if (sbbusy_i) begin
                       sbcs_d.sbbusyerror = 1'b1;
                    end begin
                        sbdata_read_valid_o = (sbcs_q.sberror == '0);
                        resp_queue_data = sbdata_q[31:0];
                    end
                end
                dm::SBData1: begin
                    // access while the SBA was busy
                    if (sbbusy_i) begin
                       sbcs_d.sbbusyerror = 1'b1;
                    end begin
                        resp_queue_data = sbdata_q[63:32];
                    end
                end
                default:;
            endcase
        end

        // write
        if (dmi_req_ready_o && dmi_req_valid_i && dtm_op == dm::DTM_WRITE) begin
            unique case (dm::dm_csr_t'({1'b0, dmi_req_i.addr})) inside
                [(dm::Data0):DataEnd]: begin
                    // attempts to write them while busy is set does not change their value
                    if (!cmdbusy_i && dm::DataCount > 0) begin
                        data_d[dmi_req_i.addr[4:0]] = dmi_req_i.data;
                        // check whether we need to re-execute the command (just give a cmd_valid)
                        cmd_valid_o = abstractauto_q.autoexecdata[dmi_req_i.addr[3:0] - int'(dm::Data0)];
                    end
                end
                dm::DMControl: begin
                    automatic dm::dmcontrol_t dmcontrol;
                    dmcontrol = dm::dmcontrol_t'(dmi_req_i.data);
                    // clear the havreset of the selected hart
                    if (dmcontrol.ackhavereset) begin
                        havereset_d[selected_hart] = 1'b0;
                    end
                    dmcontrol_d = dmi_req_i.data;
                end
                dm::DMStatus:; // write are ignored to R/O register
                dm::Hartinfo:; // hartinfo is R/O
                // only command error is write-able
                dm::AbstractCS: begin // W1C
                    // Gets set if an abstract command fails. The bits in this
                    // field remain set until they are cleared by writing 1 to
                    // them. No abstract command is started until the value is
                    // reset to 0.
                    automatic dm::abstractcs_t a_abstractcs;
                    a_abstractcs = dm::abstractcs_t'(dmi_req_i.data);
                    // reads during abstract command execution are not allowed
                    if (!cmdbusy_i) begin
                        cmderr_d = dm::cmderr_t'(~a_abstractcs.cmderr & cmderr_q);
                    end else if (cmderr_q == dm::CmdErrNone) begin
                        cmderr_d = dm::CmdErrBusy;
                    end

                end
                dm::Command: begin
                    // writes are ignored if a command is already busy
                    if (!cmdbusy_i) begin
                        cmd_valid_o = 1'b1;
                        command_d = dm::command_t'(dmi_req_i.data);
                    // if there was an attempted to write during a busy execution
                    // and the cmderror field is zero set the busy error
                    end else if (cmderr_q == dm::CmdErrNone) begin
                        cmderr_d = dm::CmdErrBusy;
                    end
                end
                dm::AbstractAuto: begin
                    // this field can only be written legally when there is no command executing
                    if (!cmdbusy_i) begin
                        abstractauto_d = {dmi_req_i.data[31:16], 4'b0, dmi_req_i.data[11:0]};
                    end else if (cmderr_q == dm::CmdErrNone) begin
                        cmderr_d = dm::CmdErrBusy;
                    end
                end
                [(dm::ProgBuf0):ProgBufEnd]: begin
                    // attempts to write them while busy is set does not change their value
                    if (!cmdbusy_i) begin
                        progbuf_d[dmi_req_i.addr[4:0]] = dmi_req_i.data;
                        // check whether we need to re-execute the command (just give a cmd_valid)
                        // this should probably throw an error if executed during another command was busy
                        // TODO(zarubaf): check if offset is correct - without it this may assign Xes
                        cmd_valid_o = abstractauto_q.autoexecprogbuf[dmi_req_i.addr[3:0]+16];
                    end
                end
                dm::SBCS: begin
                    // access while the SBA was busy
                    if (sbbusy_i) begin
                        sbcs_d.sbbusyerror = 1'b1;
                    end begin
                        automatic dm::sbcs_t sbcs = dm::sbcs_t'(dmi_req_i.data);
                        sbcs_d = sbcs;
                        // R/W1C
                        sbcs_d.sbbusyerror = sbcs_q.sbbusyerror & (~sbcs.sbbusyerror);
                        sbcs_d.sberror     = sbcs_q.sberror     & (~sbcs.sberror);
                    end
                end
                dm::SBAddress0: begin
                    // access while the SBA was busy
                    if (sbbusy_i) begin
                       sbcs_d.sbbusyerror = 1'b1;
                    end begin
                        sbaddr_d[31:0] = dmi_req_i.data;
                        sbaddress_write_valid_o = (sbcs_q.sberror == '0);
                    end
                end
                dm::SBAddress1: begin
                    // access while the SBA was busy
                    if (sbbusy_i) begin
                       sbcs_d.sbbusyerror = 1'b1;
                    end begin
                        sbaddr_d[63:32] = dmi_req_i.data;
                    end
                end
                dm::SBData0: begin
                    // access while the SBA was busy
                    if (sbbusy_i) begin
                       sbcs_d.sbbusyerror = 1'b1;
                    end begin
                        sbdata_d[31:0] = dmi_req_i.data;
                        sbdata_write_valid_o = (sbcs_q.sberror == '0);
                    end
                end
                dm::SBData1: begin
                    // access while the SBA was busy
                    if (sbbusy_i) begin
                       sbcs_d.sbbusyerror = 1'b1;
                    end begin
                        sbdata_d[63:32] = dmi_req_i.data;
                    end
                end
                default:;
            endcase
        end
        // hart threw a command error and has precedence over bus writes
        if (cmderror_valid_i) begin
            cmderr_d = cmderror_i;
        end

        // update data registers
        if (data_valid_i)
            data_d = data_i;

        // set the havereset flag when we did a ndmreset
        if (ndmreset_o) begin
            havereset_d = '1;
        end
        // -------------
        // System Bus
        // -------------
        // set bus error
        if (sberror_valid_i) begin
            sbcs_d.sberror = sberror_i;
        end
        // update read data
        if (sbdata_valid_i) begin
            sbdata_d = sbdata_i;
        end

        // dmcontrol
        // TODO(zarubaf) we currently do not implement the hartarry mask
        dmcontrol_d.hasel           = 1'b0;
        // we do not support resetting an individual hart
        dmcontrol_d.hartreset       = 1'b0;
        dmcontrol_d.setresethaltreq = 1'b0;
        dmcontrol_d.clrresethaltreq = 1'b0;
        dmcontrol_d.zero1           = '0;
        dmcontrol_d.zero0           = '0;
        // Non-writeable, clear only
        dmcontrol_d.ackhavereset    = 1'b0;
        // static values for dcsr
        sbcs_d.sbversion            = 3'b1;
        sbcs_d.sbbusy               = sbbusy_i;
        sbcs_d.sbasize              = BusWidth; // bus is 64 bit wide
        sbcs_d.sbaccess128          = 1'b0;
        sbcs_d.sbaccess64           = BusWidth == 64;
        sbcs_d.sbaccess32           = BusWidth == 32;
        sbcs_d.sbaccess16           = 1'b0;
        sbcs_d.sbaccess8            = 1'b0;
        sbcs_d.sbaccess             = BusWidth == 64 ? 2'd3 : 2'd2;
    end

    // output multiplexer
    always_comb begin
        selected_hart = hartsel_o[HartSelLen-1:0];
        // default assignment
        haltreq_o = '0;
        resumereq_o = '0;
        haltreq_o[selected_hart] = dmcontrol_q.haltreq;
        resumereq_o[selected_hart] = dmcontrol_q.resumereq;
    end

    assign dmactive_o = dmcontrol_q.dmactive;
    assign cmd_o      = command_q;
    assign progbuf_o  = progbuf_q;
    assign data_o     = data_q;

    assign resp_queue_pop = dmi_resp_ready_i & ~resp_queue_empty;

    logic ndmreset_n;

    assign ndmreset_o = dmcontrol_q.ndmreset;

    // response FIFO
    fifo_v2 #(
        .dtype            ( logic [31:0]         ),
        .DEPTH            ( 2                    )
    ) i_fifo (
        .clk_i            ( clk_i                ),
        .rst_ni           ( dmi_rst_ni           ), // reset only when system is re-set
        .flush_i          ( 1'b0                 ), // we do not need to flush this queue
        .testmode_i       ( testmode_i           ),
        .full_o           ( resp_queue_full      ),
        .empty_o          ( resp_queue_empty     ),
        .alm_full_o       (                      ),
        .alm_empty_o      (                      ),
        .data_i           ( resp_queue_data      ),
        .push_i           ( resp_queue_push      ),
        .data_o           ( dmi_resp_o.data      ),
        .pop_i            ( resp_queue_pop       )
    );

    always_ff @(posedge clk_i or negedge rst_ni) begin
        // PoR
        if (~rst_ni) begin
            dmcontrol_q    <= '0;
            // this is the only write-able bit during reset
            cmderr_q       <= dm::CmdErrNone;
            command_q      <= '0;
            abstractauto_q <= '0;
            progbuf_q      <= '0;
            data_q         <= '0;
            sbcs_q         <= '0;
            sbaddr_q       <= '0;
            sbdata_q       <= '0;
        end else begin
            // synchronous re-set of debug module, active-low, except for dmactive
            if (!dmcontrol_q.dmactive) begin
                dmcontrol_q.haltreq          <= '0;
                dmcontrol_q.resumereq        <= '0;
                dmcontrol_q.hartreset        <= '0;
                dmcontrol_q.zero1            <= '0;
                dmcontrol_q.hasel            <= '0;
                dmcontrol_q.hartsello        <= '0;
                dmcontrol_q.hartselhi        <= '0;
                dmcontrol_q.zero0            <= '0;
                dmcontrol_q.setresethaltreq  <= '0;
                dmcontrol_q.clrresethaltreq  <= '0;
                dmcontrol_q.ndmreset         <= '0;
                // this is the only write-able bit during reset
                dmcontrol_q.dmactive         <= dmcontrol_d.dmactive;
                cmderr_q                     <= dm::CmdErrNone;
                command_q                    <= '0;
                abstractauto_q               <= '0;
                progbuf_q                    <= '0;
                data_q                       <= '0;
                sbcs_q                       <= '0;
                sbaddr_q                     <= '0;
                sbdata_q                     <= '0;
            end else begin
                dmcontrol_q                  <= dmcontrol_d;
                cmderr_q                     <= cmderr_d;
                command_q                    <= command_d;
                abstractauto_q               <= abstractauto_d;
                progbuf_q                    <= progbuf_d;
                data_q                       <= data_d;
                sbcs_q                       <= sbcs_d;
                sbaddr_q                     <= sbaddr_d;
                sbdata_q                     <= sbdata_d;
            end
        end
    end


    generate
      for(genvar k=0;k < NrHarts;k++) begin
          always_ff @(posedge clk_i or negedge rst_ni) begin
              if (~rst_ni) begin
                  havereset_q[k]  <= 1'b1;
              end else begin
                  havereset_q[k]  <= Selectable_Harts[k] ? havereset_d[k]   : 1'b0;
              end
          end
      end
    endgenerate

///////////////////////////////////////////////////////
// assertions
///////////////////////////////////////////////////////


//pragma translate_off
`ifndef VERILATOR
    haltsum: assert property (
        @(posedge clk_i) disable iff (~rst_ni) (dmi_req_ready_o && dmi_req_valid_i && dtm_op == dm::DTM_READ) |->
            !({1'b0, dmi_req_i.addr} inside {dm::HaltSum0, dm::HaltSum1, dm::HaltSum2, dm::HaltSum3}))
                else $warning("Haltsums have not been properly tested yet.");
`endif
//pragma translate_on


endmodule
