/*
 * Copyright (c) 2026 Kloia
 * SPDX-License-Identifier: Apache-2.0
 *
 * Tiny Tapeout wrapper for the ultraembedded RV32IM core.
 *
 * The core's instruction and data ports are arbitrated onto a single
 * byte-serial memory bus that runs over the Tiny Tapeout pins. A host
 * (testbench, FPGA or microcontroller) services every request:
 *
 *   uo_out[7:0]  byte out      header, address, write data (LSB first)
 *   uio[0]  out  bus_valid     uo_out carries a valid byte this cycle
 *   uio[1]  out  bus_busy      a transaction is in flight
 *   uio[2]  in   bus_in_valid  host presents a read-data byte on ui_in,
 *                              or acknowledges a write (single pulse)
 *   uio[3]  in   irq           external interrupt
 *
 * Header byte:  [7] write  [6] instruction fetch  [5:4] 0  [3:0] byte enables
 * Read:   header, addr[0..3]            -> host returns data[0..3]
 * Write:  header, addr[0..3], data[0..3] -> host pulses bus_in_valid once
 */

`default_nettype none

module tt_um_kloia_rv32im (
    input  wire [7:0] ui_in,    // Dedicated inputs
    output wire [7:0] uo_out,   // Dedicated outputs
    input  wire [7:0] uio_in,   // IOs: Input path
    output wire [7:0] uio_out,  // IOs: Output path
    output wire [7:0] uio_oe,   // IOs: Enable path (active high: 0=input, 1=output)
    input  wire       ena,      // always 1 when the design is powered, so you can ignore it
    input  wire       clk,      // clock
    input  wire       rst_n     // reset_n - low to reset
);

  wire rst = ~rst_n;

  // ---------------------------------------------------------------------------
  // Core
  // ---------------------------------------------------------------------------
  wire [31:0] mem_d_addr;
  wire [31:0] mem_d_data_wr;
  wire        mem_d_rd;
  wire [ 3:0] mem_d_wr;
  wire        mem_d_cacheable;
  wire [10:0] mem_d_req_tag;
  wire        mem_d_invalidate;
  wire        mem_d_writeback;
  wire        mem_d_flush;
  wire        mem_i_rd;
  wire        mem_i_flush;
  wire        mem_i_invalidate;
  wire [31:0] mem_i_pc;

  reg  [31:0] mem_d_data_rd;
  reg         mem_d_accept;
  reg         mem_d_ack;
  reg  [10:0] mem_d_resp_tag;
  reg         mem_i_accept;
  reg         mem_i_valid;
  wire [31:0] mem_i_inst;

  riscv_core #(
      .SUPPORT_MULDIV     (1),
      .SUPPORT_SUPER      (0),
      .SUPPORT_MMU        (0),
      .SUPPORT_LOAD_BYPASS(1),
      .SUPPORT_MUL_BYPASS (1),
      .EXTRA_DECODE_STAGE (0)
  ) u_core (
      .clk_i             (clk),
      .rst_i             (rst),
      .mem_d_data_rd_i   (mem_d_data_rd),
      .mem_d_accept_i    (mem_d_accept),
      .mem_d_ack_i       (mem_d_ack),
      .mem_d_error_i     (1'b0),
      .mem_d_resp_tag_i  (mem_d_resp_tag),
      .mem_i_accept_i    (mem_i_accept),
      .mem_i_valid_i     (mem_i_valid),
      .mem_i_error_i     (1'b0),
      .mem_i_inst_i      (mem_i_inst),
      .intr_i            (uio_in[3]),
      .reset_vector_i    (32'h0000_0000),
      .cpu_id_i          (32'h0000_0000),
      .mem_d_addr_o      (mem_d_addr),
      .mem_d_data_wr_o   (mem_d_data_wr),
      .mem_d_rd_o        (mem_d_rd),
      .mem_d_wr_o        (mem_d_wr),
      .mem_d_cacheable_o (mem_d_cacheable),
      .mem_d_req_tag_o   (mem_d_req_tag),
      .mem_d_invalidate_o(mem_d_invalidate),
      .mem_d_writeback_o (mem_d_writeback),
      .mem_d_flush_o     (mem_d_flush),
      .mem_i_rd_o        (mem_i_rd),
      .mem_i_flush_o     (mem_i_flush),
      .mem_i_invalidate_o(mem_i_invalidate),
      .mem_i_pc_o        (mem_i_pc)
  );

  // ---------------------------------------------------------------------------
  // Byte-serial bus bridge
  // ---------------------------------------------------------------------------
  localparam [2:0] S_IDLE   = 3'd0;
  localparam [2:0] S_SEND   = 3'd1;  // header + address (+ data) bytes
  localparam [2:0] S_WAIT   = 3'd2;  // waiting for host data / ack
  localparam [2:0] S_DONE   = 3'd3;  // present valid / ack to core
  localparam [2:0] S_LOCAL  = 3'd4;  // flush / invalidate: ack without bus

  reg [ 2:0] state;
  reg        req_is_instr;
  reg        req_is_write;
  reg [ 3:0] req_be;
  reg [31:0] req_addr;
  reg [31:0] req_wdata;
  reg [10:0] req_tag;
  reg [ 3:0] byte_idx;
  reg [31:0] rdata;
  reg [ 1:0] rdata_idx;

  wire d_mem_req   = mem_d_rd | (|mem_d_wr);
  wire d_local_req = mem_d_flush | mem_d_invalidate | mem_d_writeback;
  wire d_req       = d_mem_req | d_local_req;
  wire idle        = (state == S_IDLE);

  // Accept at most one request per cycle; data port has priority.
  // mem_i_accept must not depend on mem_i_rd: the fetch unit only leaves
  // reset once it sees accept, so gating it on rd would deadlock the core.
  always @(*) begin
    mem_d_accept = idle & d_req;
    mem_i_accept = idle & ~d_req;
  end

  wire [3:0] send_len = req_is_write ? 4'd9 : 4'd5;

  reg [7:0] out_byte;
  always @(*) begin
    case (byte_idx)
      4'd0:    out_byte = {req_is_write, req_is_instr, 2'b00, req_be};
      4'd1:    out_byte = req_addr[7:0];
      4'd2:    out_byte = req_addr[15:8];
      4'd3:    out_byte = req_addr[23:16];
      4'd4:    out_byte = req_addr[31:24];
      4'd5:    out_byte = req_wdata[7:0];
      4'd6:    out_byte = req_wdata[15:8];
      4'd7:    out_byte = req_wdata[23:16];
      default: out_byte = req_wdata[31:24];
    endcase
  end

  always @(posedge clk or posedge rst) begin
    if (rst) begin
      state        <= S_IDLE;
      req_is_instr <= 1'b0;
      req_is_write <= 1'b0;
      req_be       <= 4'b0;
      req_addr     <= 32'b0;
      req_wdata    <= 32'b0;
      req_tag      <= 11'b0;
      byte_idx     <= 4'd0;
      rdata        <= 32'b0;
      rdata_idx    <= 2'd0;
    end else begin
      case (state)
        S_IDLE: begin
          byte_idx  <= 4'd0;
          rdata_idx <= 2'd0;
          if (d_req) begin
            req_is_instr <= 1'b0;
            req_is_write <= |mem_d_wr;
            req_be       <= mem_d_rd ? 4'b1111 : mem_d_wr;
            req_addr     <= mem_d_addr;
            req_wdata    <= mem_d_data_wr;
            req_tag      <= mem_d_req_tag;
            state        <= d_mem_req ? S_SEND : S_LOCAL;
          end else if (mem_i_rd) begin
            req_is_instr <= 1'b1;
            req_is_write <= 1'b0;
            req_be       <= 4'b1111;
            req_addr     <= mem_i_pc;
            state        <= S_SEND;
          end
        end

        S_SEND: begin
          byte_idx <= byte_idx + 4'd1;
          if (byte_idx == send_len - 4'd1)
            state <= S_WAIT;
        end

        S_WAIT: begin
          if (uio_in[2]) begin
            if (req_is_write) begin
              state <= S_DONE;
            end else begin
              case (rdata_idx)
                2'd0: rdata[7:0]   <= ui_in;
                2'd1: rdata[15:8]  <= ui_in;
                2'd2: rdata[23:16] <= ui_in;
                2'd3: rdata[31:24] <= ui_in;
              endcase
              rdata_idx <= rdata_idx + 2'd1;
              if (rdata_idx == 2'd3)
                state <= S_DONE;
            end
          end
        end

        S_LOCAL, S_DONE: begin
          state <= S_IDLE;
        end

        default: state <= S_IDLE;
      endcase
    end
  end

  wire done = (state == S_DONE) | (state == S_LOCAL);

  always @(*) begin
    mem_i_valid    = done & req_is_instr;
    mem_d_ack      = done & ~req_is_instr;
    mem_d_resp_tag = req_tag;
    mem_d_data_rd  = rdata;
  end
  assign mem_i_inst = rdata;

  // ---------------------------------------------------------------------------
  // Pins
  // ---------------------------------------------------------------------------
  wire sending = (state == S_SEND);

  assign uo_out     = sending ? out_byte : 8'h00;
  assign uio_out[0] = sending;
  assign uio_out[1] = ~idle;
  assign uio_out[7:2] = 6'b0;
  assign uio_oe     = 8'b0000_0011;

  // List all unused inputs to prevent warnings
  wire _unused = &{ena, uio_in[7:4], uio_in[1:0], mem_d_cacheable, mem_i_flush,
                   mem_i_invalidate, 1'b0};

endmodule
