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
 * File:   dm_top.sv
 * Author: Florian Zaruba <zarubaf@iis.ee.ethz.ch>
 * Date:   30.6.2018
 *
 * Description: Top-level of debug module (DM). This is an AXI-Slave.
 *              DTM protocol is equal to SiFives debug protocol to leverage
 *              SW infrastructure re-use. As of version 0.13
 */

module dm_top #(
    parameter int                 NrHarts          = -1,
    parameter int                 BusWidth         = -1,
    parameter logic [NrHarts-1:0] Selectable_Harts = -1
    /*
        PULP RISC-V cores have not continguos MHARTID.
        This leads to set the number of HARTS >= the maximum value of the MHARTID.
        In this case, the MHARD ID is {FC_Core_CLUSTER_ID,1'b0,FC_Core_CORE_ID} --> 996 (1024 chosen as power of 2)
        To avoid paying 1024 flip flop for each number of harts's related register, we implemented
        the masking parameter, aka SELECTABLE_HARTS.
        In One-Hot-Encoding way, you select 1 when that MHARTID-related HART can actally be selected.
        e.g. if you have 2 core with MHART 10 and 5, you select NrHarts=16 and SELECTABLE_HARTS = (1<<10) | (1<<5).
        This mask will be used to generated only the flip flop needed and the constant-propagator engine of the synthesizer
        will remove the other flip flops and related logic.
    */

) (
    input  logic                  clk_i,       // clock
    input  logic                  rst_ni,      // asynchronous reset active low, connect PoR here, not the system reset
    input  logic                  testmode_i,
    output logic                  ndmreset_o,  // non-debug module reset
    output logic                  dmactive_o,  // debug module is active
    output logic [NrHarts-1:0]    debug_req_o, // async debug request
    input  logic [NrHarts-1:0]    unavailable_i, // communicate whether the hart is unavailable (e.g.: power down)

    input  logic                  slave_req_i,
    input  logic                  slave_we_i,
    input  logic [BusWidth-1:0]   slave_addr_i,
    input  logic [BusWidth/8-1:0] slave_be_i,
    input  logic [BusWidth-1:0]   slave_wdata_i,
    output logic [BusWidth-1:0]   slave_rdata_o,

    output logic                  master_req_o,
    output logic [BusWidth-1:0]   master_add_o,
    output logic                  master_we_o,
    output logic [BusWidth-1:0]   master_wdata_o,
    output logic [BusWidth/8-1:0] master_be_o,
    input  logic                  master_gnt_i,
    input  logic                  master_r_valid_i,
    input  logic [BusWidth-1:0]   master_r_rdata_i,

    // Connection to DTM - compatible to RocketChip Debug Module
    input  logic                  dmi_rst_ni,
    input  logic                  dmi_req_valid_i,
    output logic                  dmi_req_ready_o,
    input  dm::dmi_req_t          dmi_req_i,

    output logic                  dmi_resp_valid_o,
    input  logic                  dmi_resp_ready_i,
    output dm::dmi_resp_t         dmi_resp_o
);

    // Debug CSRs
    dm::hartinfo_t [NrHarts-1:0]      hartinfo;
    logic [NrHarts-1:0]               halted;
    // logic [NrHarts-1:0]               running;
    logic [NrHarts-1:0]               resumeack;
    logic [NrHarts-1:0]               haltreq;
    logic [NrHarts-1:0]               resumereq;
    logic                             cmd_valid;
    dm::command_t                     cmd;

    logic                             cmderror_valid;
    dm::cmderr_t                      cmderror;
    logic                             cmdbusy;
    logic [dm::ProgBufSize-1:0][31:0] progbuf;
    logic [dm::DataCount-1:0][31:0]   data_csrs_mem;
    logic [dm::DataCount-1:0][31:0]   data_mem_csrs;
    logic                             data_valid;
    logic [19:0]                      hartsel;
    // System Bus Access Module
    logic [BusWidth-1:0]              sbaddress_csrs_sba;
    logic [BusWidth-1:0]              sbaddress_sba_csrs;
    logic                             sbaddress_write_valid;
    logic                             sbreadonaddr;
    logic                             sbautoincrement;
    logic [2:0]                       sbaccess;
    logic                             sbreadondata;
    logic [BusWidth-1:0]              sbdata_write;
    logic                             sbdata_read_valid;
    logic                             sbdata_write_valid;
    logic [BusWidth-1:0]              sbdata_read;
    logic                             sbdata_valid;
    logic                             sbbusy;
    logic                             sberror_valid;
    logic [2:0]                       sberror;


    // Debug Ctrl for each hart -> I haven't found a better way to
    // parameterize this
    for (genvar i = 0; i < NrHarts; i++) begin : dm_hart_ctrl
        assign hartinfo[i] = ariane_pkg::DebugHartInfo;
    end

    dm_csrs #(
        .NrHarts(NrHarts),
        .BusWidth(BusWidth),
        .Selectable_Harts(Selectable_Harts)
    ) i_dm_csrs (
        .clk_i                   ( clk_i                 ),
        .rst_ni                  ( rst_ni                ),
        .testmode_i              ( testmode_i            ),
        .dmi_rst_ni,
        .dmi_req_valid_i,
        .dmi_req_ready_o,
        .dmi_req_i,
        .dmi_resp_valid_o,
        .dmi_resp_ready_i,
        .dmi_resp_o,
        .ndmreset_o              ( ndmreset_o            ),
        .dmactive_o              ( dmactive_o            ),
        .hartsel_o               ( hartsel               ),
        .hartinfo_i              ( hartinfo              ),
        .halted_i                ( halted                ),
        .unavailable_i,
        .resumeack_i             ( resumeack             ),
        .haltreq_o               ( haltreq               ),
        .resumereq_o             ( resumereq             ),
        .cmd_valid_o             ( cmd_valid             ),
        .cmd_o                   ( cmd                   ),
        .cmderror_valid_i        ( cmderror_valid        ),
        .cmderror_i              ( cmderror              ),
        .cmdbusy_i               ( cmdbusy               ),
        .progbuf_o               ( progbuf               ),
        .data_i                  ( data_mem_csrs         ),
        .data_valid_i            ( data_valid            ),
        .data_o                  ( data_csrs_mem         ),
        .sbaddress_o             ( sbaddress_csrs_sba    ),
        .sbaddress_i             ( sbaddress_sba_csrs    ),
        .sbaddress_write_valid_o ( sbaddress_write_valid ),
        .sbreadonaddr_o          ( sbreadonaddr          ),
        .sbautoincrement_o       ( sbautoincrement       ),
        .sbaccess_o              ( sbaccess              ),
        .sbreadondata_o          ( sbreadondata          ),
        .sbdata_o                ( sbdata_write          ),
        .sbdata_read_valid_o     ( sbdata_read_valid     ),
        .sbdata_write_valid_o    ( sbdata_write_valid    ),
        .sbdata_i                ( sbdata_read           ),
        .sbdata_valid_i          ( sbdata_valid          ),
        .sbbusy_i                ( sbbusy                ),
        .sberror_valid_i         ( sberror_valid         ),
        .sberror_i               ( sberror               )
    );

    dm_sba #(
        .BusWidth(BusWidth)
    ) i_dm_sba (
        .clk_i                   ( clk_i                 ),
        .rst_ni                  ( rst_ni                ),
        .dmactive_i              ( dmactive_o            ),

        .master_req_o            ( master_req_o          ),
        .master_add_o            ( master_add_o          ),
        .master_we_o             ( master_we_o           ),
        .master_wdata_o          ( master_wdata_o        ),
        .master_be_o             ( master_be_o           ),
        .master_gnt_i            ( master_gnt_i          ),
        .master_r_valid_i        ( master_r_valid_i      ),
        .master_r_rdata_i        ( master_r_rdata_i      ),

        .sbaddress_i             ( sbaddress_csrs_sba    ),
        .sbaddress_o             ( sbaddress_sba_csrs    ),
        .sbaddress_write_valid_i ( sbaddress_write_valid ),
        .sbreadonaddr_i          ( sbreadonaddr          ),
        .sbautoincrement_i       ( sbautoincrement       ),
        .sbaccess_i              ( sbaccess              ),
        .sbreadondata_i          ( sbreadondata          ),
        .sbdata_i                ( sbdata_write          ),
        .sbdata_read_valid_i     ( sbdata_read_valid     ),
        .sbdata_write_valid_i    ( sbdata_write_valid    ),
        .sbdata_o                ( sbdata_read           ),
        .sbdata_valid_o          ( sbdata_valid          ),
        .sbbusy_o                ( sbbusy                ),
        .sberror_valid_o         ( sberror_valid         ),
        .sberror_o               ( sberror               )
    );

    dm_mem #(
        .NrHarts(NrHarts),
        .BusWidth(BusWidth),
        .Selectable_Harts(Selectable_Harts)
    ) i_dm_mem (
        .clk_i                   ( clk_i                 ),
        .rst_ni                  ( rst_ni                ),
        .debug_req_o             ( debug_req_o           ),
        .hartsel_i               ( hartsel               ),
        .haltreq_i               ( haltreq               ),
        .resumereq_i             ( resumereq             ),
        .halted_o                ( halted                ),
        .resuming_o              ( resumeack             ),
        .cmd_valid_i             ( cmd_valid             ),
        .cmd_i                   ( cmd                   ),
        .cmderror_valid_o        ( cmderror_valid        ),
        .cmderror_o              ( cmderror              ),
        .cmdbusy_o               ( cmdbusy               ),
        .progbuf_i               ( progbuf               ),
        .data_i                  ( data_csrs_mem         ),
        .data_o                  ( data_mem_csrs         ),
        .data_valid_o            ( data_valid            ),
        .req_i                   ( slave_req_i           ),
        .we_i                    ( slave_we_i            ),
        .addr_i                  ( slave_addr_i          ),
        .wdata_i                 ( slave_wdata_i         ),
        .be_i                    ( slave_be_i            ),
        .rdata_o                 ( slave_rdata_o         )
    );

endmodule
