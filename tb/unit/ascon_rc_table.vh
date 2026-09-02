// Shared round-constant lookup for unit testbenches (tb_sbox.v,
// tb_linear.v). Transcribed once here so it is not typed twice; the
// authoritative synthesizable copy lives in rtl/core/ascon_round.v.
// Must be `include`-d inside a module body (function declaration).

function [7:0] tb_rc;
    input [3:0] idx;
    begin
        case (idx)
            4'd0:  tb_rc = 8'h3c;
            4'd1:  tb_rc = 8'h2d;
            4'd2:  tb_rc = 8'h1e;
            4'd3:  tb_rc = 8'h0f;
            4'd4:  tb_rc = 8'hf0;
            4'd5:  tb_rc = 8'he1;
            4'd6:  tb_rc = 8'hd2;
            4'd7:  tb_rc = 8'hc3;
            4'd8:  tb_rc = 8'hb4;
            4'd9:  tb_rc = 8'ha5;
            4'd10: tb_rc = 8'h96;
            4'd11: tb_rc = 8'h87;
            4'd12: tb_rc = 8'h78;
            4'd13: tb_rc = 8'h69;
            4'd14: tb_rc = 8'h5a;
            4'd15: tb_rc = 8'h4b;
            default: tb_rc = 8'h00;
        endcase
    end
endfunction
