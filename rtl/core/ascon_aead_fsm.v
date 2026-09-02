// Ascon-AEAD128 core control FSM. Implements the operation sequence
// from docs/spec.md 8.1/8.2 on top of a single ascon_perm permutation
// engine, per the state table in docs/uarch.md section 2.
//
// Two-process style: one sequential block holds every register (FSM
// state plus all latched/registered outputs), one combinational block
// computes every next-value with defaults assigned up front so no
// latch can be inferred.

module ascon_aead_fsm (
    input  wire         clk,
    input  wire         rst_n,

    input  wire         start,
    input  wire [2:0]   opcode,
    input  wire         last,
    input  wire         mode,
    input  wire [4:0]   valid_bytes,
    input  wire [127:0] key,
    input  wire [127:0] nonce,
    input  wire [127:0] din,
    input  wire [127:0] tag_in,

    output wire         busy,
    output wire         done,
    output wire [127:0] dout,
    output wire         dout_valid,
    output wire [127:0] tag,
    output wire         tag_valid,
    output wire         tag_fail
);

    // opcode encoding (docs/spec.md 7.1)
    localparam OP_INIT       = 3'd1;
    localparam OP_PROC_AD    = 3'd2;
    localparam OP_PROC_TEXT  = 3'd3;
    localparam OP_FINAL      = 3'd4;
    localparam OP_SOFT_RESET = 3'd7;

    // FSM states (docs/uarch.md section 2)
    localparam S_IDLE        = 3'd0;
    localparam S_LOAD        = 3'd1;
    localparam S_XOR_IN      = 3'd2;
    localparam S_PERM        = 3'd3;
    localparam S_INIT_KEYXOR = 3'd4;
    localparam S_FIN_KEYXOR  = 3'd5;
    localparam S_FIN_TAGXOR  = 3'd6;

    localparam [63:0] IV_CONST = 64'h00001000808c0001;
    localparam [63:0] DOMAIN_SEP = 64'h8000000000000000;

    // ---- registers ---------------------------------------------------
    reg [2:0]   state, ret_state;
    reg [3:0]   round_start_r;
    reg         first_pt_done_r;
    reg [2:0]   op_r;
    reg         last_r, mode_r;
    reg [4:0]   vbytes_r;
    reg         done_r;
    reg [127:0] dout_r;
    reg         dout_valid_r;
    reg [127:0] tag_r;
    reg         tag_valid_r, tag_fail_r;
    reg [127:0] last_pt_r; // decrypt only: held last-block plaintext,
                            // released (or blocked) at S_FIN_TAGXOR

    // ---- ascon_perm instance ------------------------------------------
    reg  [319:0] perm_state_i;
    reg          perm_load;
    wire         perm_start;
    wire [3:0]   perm_round_start;
    wire         perm_busy, perm_done;
    wire [319:0] perm_state_o;

    ascon_perm u_perm (
        .clk         (clk),
        .rst_n       (rst_n),
        .state_i     (perm_state_i),
        .load        (perm_load),
        .start       (perm_start),
        .round_start (perm_round_start),
        .busy        (perm_busy),
        .done        (perm_done),
        .state_o     (perm_state_o)
    );

    assign perm_start       = (state == S_PERM) && !perm_busy && !perm_done;
    assign perm_round_start = round_start_r;

    wire [63:0] s0_cur = perm_state_o[319:256];
    wire [63:0] s1_cur = perm_state_o[255:192];
    wire [63:0] s2_cur = perm_state_o[191:128];
    wire [63:0] s3_cur = perm_state_o[127:64];
    wire [63:0] s4_cur = perm_state_o[63:0];

    // ---- byte-lane pad/merge helpers for the rate (S0/S1) -------------
    // Mirror model/ascon_model.py pad16()/encrypt()/decrypt() exactly:
    // byte k < valid_bytes -> real data; byte k == valid_bytes -> 0x01
    // pad marker; byte k > valid_bytes -> unchanged. Only applied when
    // is_last=1; non-last blocks are always full 16-byte XOR/overwrite.
    //
    // Rewritten as a flat `case` on valid_bytes (17 branches, 0..16):
    // each branch concatenates the final 128-bit result directly from
    // literal bit ranges, so there is no `<`/`>` comparison operator in
    // this file and no reusable "is byte i before the boundary" signal
    // for a technology mapper to recognize as a magnitude compare. This
    // did shrink the design (1824 -> 1566 LUTs on xc7a35tcpg236-1, see
    // docs/BUGS.md) but did NOT remove the 11-CARRY4 chain on dout_r
    // that motivated the rewrite -- that turned out to depend on the
    // unrelated 128-bit tag comparison in S_FIN_TAGXOR (next_tag !=
    // tag_in) being present elsewhere in the same module; removing only
    // that comparison (independently of this rewrite) also removed the
    // chain. Per-signal and per-module `(* use_carry = "no" *)`,
    // `dont_touch`, and `synth_design -resource_sharing off` were all
    // tried and did not break that interaction (see docs/BUGS.md for
    // the full record). Root cause not resolved; documented rather than
    // masked with attributes that were confirmed ineffective.

    function [127:0] f_enc_rate;
        input [127:0] rate_old;
        input [127:0] d;
        input         is_last;
        input [4:0]   vbytes;
        reg [127:0] full_xor;
        reg [127:0] result;
        begin
            full_xor = rate_old ^ d;
            if (!is_last) begin
                result = full_xor;
            end else begin
                case (vbytes)
                    5'd0:    result = { rate_old[127:8],                                     rate_old[7:0]    ^ 8'h01 };
                    5'd1:    result = { rate_old[127:16],  rate_old[15:8]   ^ 8'h01, full_xor[7:0]   };
                    5'd2:    result = { rate_old[127:24],  rate_old[23:16]  ^ 8'h01, full_xor[15:0]  };
                    5'd3:    result = { rate_old[127:32],  rate_old[31:24]  ^ 8'h01, full_xor[23:0]  };
                    5'd4:    result = { rate_old[127:40],  rate_old[39:32]  ^ 8'h01, full_xor[31:0]  };
                    5'd5:    result = { rate_old[127:48],  rate_old[47:40]  ^ 8'h01, full_xor[39:0]  };
                    5'd6:    result = { rate_old[127:56],  rate_old[55:48]  ^ 8'h01, full_xor[47:0]  };
                    5'd7:    result = { rate_old[127:64],  rate_old[63:56]  ^ 8'h01, full_xor[55:0]  };
                    5'd8:    result = { rate_old[127:72],  rate_old[71:64]  ^ 8'h01, full_xor[63:0]  };
                    5'd9:    result = { rate_old[127:80],  rate_old[79:72]  ^ 8'h01, full_xor[71:0]  };
                    5'd10:   result = { rate_old[127:88],  rate_old[87:80]  ^ 8'h01, full_xor[79:0]  };
                    5'd11:   result = { rate_old[127:96],  rate_old[95:88]  ^ 8'h01, full_xor[87:0]  };
                    5'd12:   result = { rate_old[127:104], rate_old[103:96] ^ 8'h01, full_xor[95:0]  };
                    5'd13:   result = { rate_old[127:112], rate_old[111:104]^ 8'h01, full_xor[103:0] };
                    5'd14:   result = { rate_old[127:120], rate_old[119:112]^ 8'h01, full_xor[111:0] };
                    5'd15:   result = { rate_old[127:120] ^ 8'h01,                   full_xor[119:0] };
                    5'd16:   result = full_xor;
                    default: result = full_xor;
                endcase
            end
            f_enc_rate = result;
        end
    endfunction

    function [127:0] f_dec_rate;
        input [127:0] rate_old;
        input [127:0] d;
        input         is_last;
        input [4:0]   vbytes;
        reg [127:0] result;
        begin
            if (!is_last) begin
                result = d;
            end else begin
                case (vbytes)
                    5'd0:    result = { rate_old[127:8],                                     rate_old[7:0]    ^ 8'h01 };
                    5'd1:    result = { rate_old[127:16],  rate_old[15:8]   ^ 8'h01, d[7:0]   };
                    5'd2:    result = { rate_old[127:24],  rate_old[23:16]  ^ 8'h01, d[15:0]  };
                    5'd3:    result = { rate_old[127:32],  rate_old[31:24]  ^ 8'h01, d[23:0]  };
                    5'd4:    result = { rate_old[127:40],  rate_old[39:32]  ^ 8'h01, d[31:0]  };
                    5'd5:    result = { rate_old[127:48],  rate_old[47:40]  ^ 8'h01, d[39:0]  };
                    5'd6:    result = { rate_old[127:56],  rate_old[55:48]  ^ 8'h01, d[47:0]  };
                    5'd7:    result = { rate_old[127:64],  rate_old[63:56]  ^ 8'h01, d[55:0]  };
                    5'd8:    result = { rate_old[127:72],  rate_old[71:64]  ^ 8'h01, d[63:0]  };
                    5'd9:    result = { rate_old[127:80],  rate_old[79:72]  ^ 8'h01, d[71:0]  };
                    5'd10:   result = { rate_old[127:88],  rate_old[87:80]  ^ 8'h01, d[79:0]  };
                    5'd11:   result = { rate_old[127:96],  rate_old[95:88]  ^ 8'h01, d[87:0]  };
                    5'd12:   result = { rate_old[127:104], rate_old[103:96] ^ 8'h01, d[95:0]  };
                    5'd13:   result = { rate_old[127:112], rate_old[111:104]^ 8'h01, d[103:0] };
                    5'd14:   result = { rate_old[127:120], rate_old[119:112]^ 8'h01, d[111:0] };
                    5'd15:   result = { rate_old[127:120] ^ 8'h01,                   d[119:0] };
                    5'd16:   result = d;
                    default: result = d;
                endcase
            end
            f_dec_rate = result;
        end
    endfunction

    wire [127:0] rate_old        = { s1_cur, s0_cur };
    wire         domain_sep_now  = (op_r == OP_PROC_TEXT) && !first_pt_done_r;
    wire         is_decrypt_text = (op_r == OP_PROC_TEXT) && mode_r;

    wire [127:0] rate_new = is_decrypt_text
                              ? f_dec_rate(rate_old, din, last_r, vbytes_r)
                              : f_enc_rate(rate_old, din, last_r, vbytes_r);

    wire [127:0] dout_calc = is_decrypt_text ? (rate_old ^ din) : rate_new;

    // ---- combinational next-state / next-output logic -----------------
    reg [2:0]   next_state, next_ret_state;
    reg [3:0]   next_round_start;
    reg         next_first_pt;
    reg [2:0]   next_op;
    reg         next_last, next_mode;
    reg [4:0]   next_vbytes;
    reg         next_done;
    reg [127:0] next_dout;
    reg         next_dout_valid;
    reg [127:0] next_tag;
    reg         next_tag_valid, next_tag_fail;
    reg [127:0] next_last_pt;

    always @(*) begin
        // defaults -- avoid latches
        next_state       = state;
        next_ret_state   = ret_state;
        next_round_start = round_start_r;
        next_first_pt    = first_pt_done_r;
        next_op          = op_r;
        next_last        = last_r;
        next_mode        = mode_r;
        next_vbytes      = vbytes_r;
        next_done        = 1'b0;
        next_dout        = dout_r;
        next_dout_valid  = 1'b0;
        next_tag         = tag_r;
        next_tag_valid   = 1'b0;
        next_tag_fail    = tag_fail_r;
        next_last_pt     = last_pt_r;

        perm_state_i = perm_state_o;
        perm_load    = 1'b0;

        case (state)
            S_IDLE: begin
                if (start) begin
                    next_op     = opcode;
                    next_last   = last;
                    next_mode   = mode;
                    next_vbytes = valid_bytes;
                    case (opcode)
                        OP_INIT: begin
                            next_state = S_LOAD;
                        end
                        OP_PROC_AD, OP_PROC_TEXT: begin
                            next_state = S_XOR_IN;
                        end
                        OP_FINAL: begin
                            next_state = S_FIN_KEYXOR;
                        end
                        OP_SOFT_RESET: begin
                            next_first_pt = 1'b0;
                            next_done     = 1'b1;
                            next_state    = S_IDLE;
                        end
                        default: begin
                            next_state = S_IDLE; // NOP / reserved opcode
                        end
                    endcase
                end
            end

            S_LOAD: begin
                perm_state_i = { IV_CONST, key[63:0], key[127:64],
                                  nonce[63:0], nonce[127:64] };
                perm_load        = 1'b1;
                next_round_start = 4'd4;
                next_ret_state   = S_INIT_KEYXOR;
                next_first_pt    = 1'b0;
                next_state       = S_PERM;
            end

            S_XOR_IN: begin
                perm_state_i = { rate_new[63:0], rate_new[127:64],
                                  s2_cur, s3_cur,
                                  s4_cur ^ (domain_sep_now ? DOMAIN_SEP : 64'h0) };
                perm_load = 1'b1;

                if (op_r == OP_PROC_TEXT) begin
                    next_first_pt = 1'b1;
                    if (mode_r && last_r) begin
                        // decrypt, last block: do not reveal yet -- hold
                        // until S_FIN_TAGXOR, blocked entirely if the tag
                        // turns out to fail (docs/spec.md 9.5)
                        next_last_pt = dout_calc;
                    end else begin
                        next_dout       = dout_calc;
                        next_dout_valid = 1'b1;
                    end
                end

                if (op_r == OP_PROC_AD || (op_r == OP_PROC_TEXT && !last_r)) begin
                    next_round_start = 4'd8;
                    next_ret_state   = S_IDLE;
                    next_state       = S_PERM;
                end else begin // OP_PROC_TEXT && last_r: skip p8
                    next_done  = 1'b1;
                    next_state = S_IDLE;
                end
            end

            S_PERM: begin
                if (perm_done) begin
                    next_state = ret_state;
                    if (ret_state == S_IDLE)
                        next_done = 1'b1;
                end
            end

            S_INIT_KEYXOR: begin
                perm_state_i = { s0_cur, s1_cur, s2_cur,
                                  s3_cur ^ key[63:0], s4_cur ^ key[127:64] };
                perm_load  = 1'b1;
                next_done  = 1'b1;
                next_state = S_IDLE;
            end

            S_FIN_KEYXOR: begin
                perm_state_i = { s0_cur, s1_cur,
                                  s2_cur ^ key[63:0], s3_cur ^ key[127:64],
                                  s4_cur };
                perm_load        = 1'b1;
                next_round_start = 4'd4;
                next_ret_state   = S_FIN_TAGXOR;
                next_state       = S_PERM;
            end

            S_FIN_TAGXOR: begin
                next_tag       = { s4_cur ^ key[127:64], s3_cur ^ key[63:0] };
                next_tag_valid = 1'b1;
                next_tag_fail  = mode_r ? (next_tag != tag_in) : 1'b0;
                next_done      = 1'b1;
                next_state     = S_IDLE;

                if (mode_r && !next_tag_fail) begin
                    // decrypt, tag OK: release the held last block now
                    next_dout       = last_pt_r;
                    next_dout_valid = 1'b1;
                end
                // decrypt, tag_fail: last block stays blocked -- dout_valid
                // is never asserted for it, dout keeps its old value
            end

            default: begin
                next_state = S_IDLE;
            end
        endcase
    end

    // ---- sequential register bank --------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state           <= S_IDLE;
            ret_state       <= S_IDLE;
            round_start_r   <= 4'd0;
            first_pt_done_r <= 1'b0;
            op_r            <= 3'd0;
            last_r          <= 1'b0;
            mode_r          <= 1'b0;
            vbytes_r        <= 5'd0;
            done_r          <= 1'b0;
            dout_r          <= 128'h0;
            dout_valid_r    <= 1'b0;
            tag_r           <= 128'h0;
            tag_valid_r     <= 1'b0;
            tag_fail_r      <= 1'b0;
            last_pt_r       <= 128'h0;
        end else begin
            state           <= next_state;
            ret_state       <= next_ret_state;
            round_start_r   <= next_round_start;
            first_pt_done_r <= next_first_pt;
            op_r            <= next_op;
            last_r          <= next_last;
            mode_r          <= next_mode;
            vbytes_r        <= next_vbytes;
            done_r          <= next_done;
            dout_r          <= next_dout;
            dout_valid_r    <= next_dout_valid;
            tag_r           <= next_tag;
            tag_valid_r     <= next_tag_valid;
            tag_fail_r      <= next_tag_fail;
            last_pt_r       <= next_last_pt;
        end
    end

    assign busy       = (state != S_IDLE);
    assign done        = done_r;
    assign dout        = dout_r;
    assign dout_valid  = dout_valid_r;
    assign tag         = tag_r;
    assign tag_valid   = tag_valid_r;
    assign tag_fail    = tag_fail_r;

endmodule
