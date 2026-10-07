//-----------------------------------------------------------------
//                         RISC-V Core
//                            V1.0.1
//                     Ultra-Embedded.com
//                     Copyright 2014-2019
//
//                   admin@ultra-embedded.com
//
//                       License: BSD
//-----------------------------------------------------------------
//
// Copyright (c) 2014-2019, Ultra-Embedded.com
// All rights reserved.
// 
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions 
// are met:
//   - Redistributions of source code must retain the above copyright
//     notice, this list of conditions and the following disclaimer.
//   - Redistributions in binary form must reproduce the above copyright
//     notice, this list of conditions and the following disclaimer 
//     in the documentation and/or other materials provided with the 
//     distribution.
//   - Neither the name of the author nor the names of its contributors 
//     may be used to endorse or promote products derived from this 
//     software without specific prior written permission.
// 
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS 
// "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT 
// LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR 
// A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE AUTHOR BE 
// LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR 
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF 
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR 
// BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF 
// LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF 
// THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF 
// SUCH DAMAGE.
//-----------------------------------------------------------------

module riscv_divider
(
    // Inputs
     input           clk_i
    ,input           rst_i
    ,input           opcode_valid_i
    ,input  [ 31:0]  opcode_opcode_i
    ,input  [ 31:0]  opcode_pc_i
    ,input           opcode_invalid_i
    ,input  [  4:0]  opcode_rd_idx_i
    ,input  [  4:0]  opcode_ra_idx_i
    ,input  [  4:0]  opcode_rb_idx_i
    ,input  [ 31:0]  opcode_ra_operand_i
    ,input  [ 31:0]  opcode_rb_operand_i

    // Outputs
    ,output          writeback_valid_o
    ,output [ 31:0]  writeback_value_o
);



//-----------------------------------------------------------------
// Includes
//-----------------------------------------------------------------
`include "riscv_defs.v"

//-------------------------------------------------------------
// Registers / Wires
//-------------------------------------------------------------
reg          valid_q;
reg  [31:0]  wb_result_q;

//-------------------------------------------------------------
// Divider
//-------------------------------------------------------------
wire inst_div_w         = (opcode_opcode_i & `INST_DIV_MASK) == `INST_DIV;
wire inst_divu_w        = (opcode_opcode_i & `INST_DIVU_MASK) == `INST_DIVU;
wire inst_rem_w         = (opcode_opcode_i & `INST_REM_MASK) == `INST_REM;
wire inst_remu_w        = (opcode_opcode_i & `INST_REMU_MASK) == `INST_REMU;

wire div_rem_inst_w     = ((opcode_opcode_i & `INST_DIV_MASK) == `INST_DIV)  || 
                          ((opcode_opcode_i & `INST_DIVU_MASK) == `INST_DIVU) ||
                          ((opcode_opcode_i & `INST_REM_MASK) == `INST_REM)  ||
                          ((opcode_opcode_i & `INST_REMU_MASK) == `INST_REMU);

wire signed_operation_w = ((opcode_opcode_i & `INST_DIV_MASK) == `INST_DIV) || ((opcode_opcode_i & `INST_REM_MASK) == `INST_REM);
wire div_operation_w    = ((opcode_opcode_i & `INST_DIV_MASK) == `INST_DIV) || ((opcode_opcode_i & `INST_DIVU_MASK) == `INST_DIVU);

// Kloia change: multiply runs through this iterative unit as well (32 cycles,
// shift-and-add) instead of the pipelined array multiplier, which alone was
// ~30% of the design area. The decoder issues MUL* on the div path.
wire inst_mul_w         = (opcode_opcode_i & `INST_MUL_MASK) == `INST_MUL;
wire inst_mulh_w        = (opcode_opcode_i & `INST_MULH_MASK) == `INST_MULH;
wire inst_mulhsu_w      = (opcode_opcode_i & `INST_MULHSU_MASK) == `INST_MULHSU;
wire inst_mulhu_w       = (opcode_opcode_i & `INST_MULHU_MASK) == `INST_MULHU;
wire mul_inst_w         = inst_mul_w | inst_mulh_w | inst_mulhsu_w | inst_mulhu_w;

// Multiply on magnitudes; fix the sign of the 64-bit product afterwards.
wire mul_a_neg_w        = (inst_mulh_w | inst_mulhsu_w) & opcode_ra_operand_i[31];
wire mul_b_neg_w        = inst_mulh_w & opcode_rb_operand_i[31];

reg [31:0] dividend_q;      // divide: remainder    multiply: multiplier bits (shifted out)
reg [62:0] divisor_q;       // divide: divisor      multiply: [31:0] multiplicand
reg [31:0] quotient_q;
reg [31:0] q_mask_q;        // one-hot step counter for both operations
reg        div_inst_q;
reg        div_busy_q;
reg        invert_res_q;
reg        mul_inst_q;
reg        mul_hi_q;
reg [63:0] mul_acc_q;

wire div_start_w    = opcode_valid_i & (div_rem_inst_w | mul_inst_w);
wire div_complete_w = !(|q_mask_q) & div_busy_q;

// One shift-and-add step: add the multiplicand into the upper half when the
// current multiplier bit is set, then shift the 65-bit result right by one.
wire [32:0] mul_sum_w  = {1'b0, mul_acc_q[63:32]} + (dividend_q[0] ? {1'b0, divisor_q[31:0]} : 33'b0);
wire [63:0] mul_next_w = {mul_sum_w, mul_acc_q[31:1]};

always @(posedge clk_i or posedge rst_i)
if (rst_i)
begin
    div_busy_q     <= 1'b0;
    dividend_q     <= 32'b0;
    divisor_q      <= 63'b0;
    invert_res_q   <= 1'b0;
    quotient_q     <= 32'b0;
    q_mask_q       <= 32'b0;
    div_inst_q     <= 1'b0;
    mul_inst_q     <= 1'b0;
    mul_hi_q       <= 1'b0;
    mul_acc_q      <= 64'b0;
end
else if (div_start_w && mul_inst_w)
begin
    div_busy_q     <= 1'b1;
    div_inst_q     <= 1'b0;
    mul_inst_q     <= 1'b1;
    mul_hi_q       <= ~inst_mul_w;

    dividend_q     <= mul_b_neg_w ? -opcode_rb_operand_i : opcode_rb_operand_i;
    divisor_q      <= {31'b0, mul_a_neg_w ? -opcode_ra_operand_i : opcode_ra_operand_i};
    invert_res_q   <= mul_a_neg_w ^ mul_b_neg_w;

    mul_acc_q      <= 64'b0;
    quotient_q     <= 32'b0;
    q_mask_q       <= 32'h80000000;
end
else if (div_start_w)
begin

    div_busy_q     <= 1'b1;
    div_inst_q     <= div_operation_w;
    mul_inst_q     <= 1'b0;

    if (signed_operation_w && opcode_ra_operand_i[31])
        dividend_q <= -opcode_ra_operand_i;
    else
        dividend_q <= opcode_ra_operand_i;

    if (signed_operation_w && opcode_rb_operand_i[31])
        divisor_q <= {-opcode_rb_operand_i, 31'b0};
    else
        divisor_q <= {opcode_rb_operand_i, 31'b0};

    invert_res_q  <= (((opcode_opcode_i & `INST_DIV_MASK) == `INST_DIV) && (opcode_ra_operand_i[31] != opcode_rb_operand_i[31]) && |opcode_rb_operand_i) || 
                     (((opcode_opcode_i & `INST_REM_MASK) == `INST_REM) && opcode_ra_operand_i[31]);

    quotient_q     <= 32'b0;
    q_mask_q       <= 32'h80000000;
end
else if (div_complete_w)
begin
    div_busy_q <= 1'b0;
end
else if (div_busy_q && mul_inst_q)
begin
    mul_acc_q  <= mul_next_w;
    dividend_q <= {1'b0, dividend_q[31:1]};
    q_mask_q   <= {1'b0, q_mask_q[31:1]};
end
else if (div_busy_q)
begin
    if (divisor_q <= {31'b0, dividend_q})
    begin
        dividend_q <= dividend_q - divisor_q[31:0];
        quotient_q <= quotient_q | q_mask_q;
    end

    divisor_q <= {1'b0, divisor_q[62:1]};
    q_mask_q  <= {1'b0, q_mask_q[31:1]};
end

wire [63:0] mul_product_w = invert_res_q ? -mul_acc_q : mul_acc_q;

reg [31:0] div_result_r;
always @ *
begin
    div_result_r = 32'b0;

    if (mul_inst_q)
        div_result_r = mul_hi_q ? mul_product_w[63:32] : mul_product_w[31:0];
    else if (div_inst_q)
        div_result_r = invert_res_q ? -quotient_q : quotient_q;
    else
        div_result_r = invert_res_q ? -dividend_q : dividend_q;
end

always @(posedge clk_i or posedge rst_i)
if (rst_i)
    valid_q <= 1'b0;
else
    valid_q <= div_complete_w;

always @(posedge clk_i or posedge rst_i)
if (rst_i)
    wb_result_q <= 32'b0;
else if (div_complete_w)
    wb_result_q <= div_result_r;

assign writeback_valid_o = valid_q;
assign writeback_value_o  = wb_result_q;



endmodule
