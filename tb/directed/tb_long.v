// Long-message testbench for ascon_aead_fsm: the NIST KAT stops at
// 32-byte AD/PT (at most 3 blocks), so this replays 60 random vectors
// with AD/PT up to 255 bytes (up to 16 blocks), generated from
// model/ascon_model.py by tb/directed/gen_long_vectors.py.
//
// Per vector:
//   - encrypt: every DOUT block (all 128 bits, last block masked to
//     valid_bytes) and the tag must match the model;
//   - decrypt: every non-last block's plaintext must match, the last
//     block must stay held until FINAL, then be released with the
//     right bytes and tag_fail=0.

`timescale 1ns/1ps

module tb_long;

    localparam OP_INIT      = 3'd1;
    localparam OP_PROC_AD   = 3'd2;
    localparam OP_PROC_TEXT = 3'd3;
    localparam OP_FINAL     = 3'd4;

    localparam MAX_BLOCKS = 32;
    localparam MEM_WORDS  = 16384;

    reg clk, rst_n;
    reg start_r;
    reg [2:0]   opcode_r;
    reg         last_r, mode_r;
    reg [4:0]   vbytes_r;
    reg [127:0] key_r, nonce_r, din_r, tag_in_r;

    wire         busy_o, done_o, dout_valid_o, tag_valid_o, tag_fail_o;
    wire [127:0] dout_o, tag_o;

    ascon_aead_fsm dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .start       (start_r),
        .opcode      (opcode_r),
        .last        (last_r),
        .mode        (mode_r),
        .valid_bytes (vbytes_r),
        .key         (key_r),
        .nonce       (nonce_r),
        .din         (din_r),
        .tag_in      (tag_in_r),
        .busy        (busy_o),
        .done        (done_o),
        .dout        (dout_o),
        .dout_valid  (dout_valid_o),
        .tag         (tag_o),
        .tag_valid   (tag_valid_o),
        .tag_fail    (tag_fail_o)
    );

    always #5 clk = ~clk;

    reg [63:0] mem [0:MEM_WORDS-1];
    integer p;

    task get;
        output [63:0] w;
        begin
            w = mem[p];
            p = p + 1;
        end
    endtask

    function [127:0] byte_mask;
        input [4:0] vbytes;
        integer k;
        reg [127:0] m;
        begin
            m = 128'h0;
            for (k = 0; k < 16; k = k + 1)
                if (k < vbytes) m[8*k +: 8] = 8'hFF;
            byte_mask = m;
        end
    endfunction

    reg [127:0] cap_dout, cap_tag;
    reg         cap_dout_seen, cap_tag_seen;

    task issue_cmd;
        input [2:0]   op;
        input         lst;
        input [4:0]   vb;
        input [127:0] d;
        input         md;
        begin
            cap_dout_seen = 1'b0;
            cap_tag_seen  = 1'b0;
            @(negedge clk);
            opcode_r = op; last_r = lst; mode_r = md; vbytes_r = vb; din_r = d;
            start_r  = 1'b1;
            @(negedge clk);
            start_r = 1'b0;
            while (!done_o) begin
                if (dout_valid_o) begin cap_dout = dout_o; cap_dout_seen = 1'b1; end
                if (tag_valid_o)  begin cap_tag  = tag_o;  cap_tag_seen  = 1'b1; end
                @(negedge clk);
            end
            if (dout_valid_o) begin cap_dout = dout_o; cap_dout_seen = 1'b1; end
            if (tag_valid_o)  begin cap_tag  = tag_o;  cap_tag_seen  = 1'b1; end
        end
    endtask

    // one parsed vector
    reg [127:0] ad_d  [0:MAX_BLOCKS-1];
    reg         ad_l  [0:MAX_BLOCKS-1];
    reg [4:0]   ad_vb [0:MAX_BLOCKS-1];
    reg [127:0] pt_d  [0:MAX_BLOCKS-1];
    reg         pt_l  [0:MAX_BLOCKS-1];
    reg [4:0]   pt_vb [0:MAX_BLOCKS-1];
    reg [127:0] ct_d  [0:MAX_BLOCKS-1];
    reg [127:0] exp_tag;
    integer     n_ad, n_pt;

    reg [63:0] w0, w1, w2, w3;
    integer    i;

    task parse_vector;
        begin
            get(w0); get(w1); key_r   = { w1, w0 };
            get(w0); get(w1); nonce_r = { w1, w0 };
            get(w0); n_ad = w0;
            get(w0); n_pt = w0;
            for (i = 0; i < n_ad; i = i + 1) begin
                get(w0); get(w1); get(w2); get(w3);
                ad_d[i] = { w1, w0 }; ad_l[i] = w2[0]; ad_vb[i] = w3[4:0];
            end
            for (i = 0; i < n_pt; i = i + 1) begin
                get(w0); get(w1); get(w2); get(w3);
                pt_d[i] = { w1, w0 }; pt_l[i] = w2[0]; pt_vb[i] = w3[4:0];
            end
            for (i = 0; i < n_pt; i = i + 1) begin
                get(w0); get(w1);
                ct_d[i] = { w1, w0 };
            end
            get(w0); get(w1); exp_tag = { w1, w0 };
        end
    endtask

    reg enc_bad, dec_bad;
    reg [127:0] expd;

    task run_encrypt;
        begin
            enc_bad = 1'b0;
            issue_cmd(OP_INIT, 1'b0, 5'd0, 128'h0, 1'b0);
            for (i = 0; i < n_ad; i = i + 1)
                issue_cmd(OP_PROC_AD, ad_l[i], ad_vb[i], ad_d[i], 1'b0);
            for (i = 0; i < n_pt; i = i + 1) begin
                issue_cmd(OP_PROC_TEXT, pt_l[i], pt_vb[i], pt_d[i], 1'b0);
                expd = pt_l[i] ? (ct_d[i] & byte_mask(pt_vb[i])) : ct_d[i];
                if (!cap_dout_seen || cap_dout !== expd) enc_bad = 1'b1;
            end
            issue_cmd(OP_FINAL, 1'b0, 5'd0, 128'h0, 1'b0);
            if (!cap_tag_seen || cap_tag !== exp_tag) enc_bad = 1'b1;
        end
    endtask

    task run_decrypt;
        begin
            dec_bad = 1'b0;
            tag_in_r = exp_tag;
            issue_cmd(OP_INIT, 1'b0, 5'd0, 128'h0, 1'b1);
            for (i = 0; i < n_ad; i = i + 1)
                issue_cmd(OP_PROC_AD, ad_l[i], ad_vb[i], ad_d[i], 1'b1);
            for (i = 0; i < n_pt; i = i + 1) begin
                issue_cmd(OP_PROC_TEXT, pt_l[i], pt_vb[i], ct_d[i], 1'b1);
                if (pt_l[i]) begin
                    if (cap_dout_seen) dec_bad = 1'b1;          // must be held
                end else begin
                    if (!cap_dout_seen || cap_dout !== pt_d[i]) dec_bad = 1'b1;
                end
            end
            issue_cmd(OP_FINAL, 1'b0, 5'd0, 128'h0, 1'b1);
            if (tag_fail_o || cap_tag_seen) dec_bad = 1'b1;     // no tag published
            if (!cap_dout_seen ||
                cap_dout !== (pt_d[n_pt-1] & byte_mask(pt_vb[n_pt-1])))
                dec_bad = 1'b1;
        end
    endtask

    integer n_vec, v, enc_pass, dec_pass, blocks_max;

    initial begin
        $readmemh("tb/directed/long_vectors.hex", mem);
        clk = 1'b0; rst_n = 1'b0; start_r = 1'b0;
        opcode_r = 3'd0; last_r = 1'b0; mode_r = 1'b0; vbytes_r = 5'd0;
        key_r = 128'h0; nonce_r = 128'h0; din_r = 128'h0; tag_in_r = 128'h0;
        enc_pass = 0; dec_pass = 0; blocks_max = 0;

        @(negedge clk); @(negedge clk);
        rst_n = 1'b1;

        p = 0;
        get(w0); n_vec = w0;
        for (v = 0; v < n_vec; v = v + 1) begin
            parse_vector;
            if (n_ad > blocks_max) blocks_max = n_ad;
            if (n_pt > blocks_max) blocks_max = n_pt;
            run_encrypt;
            run_decrypt;
            if (!enc_bad) enc_pass = enc_pass + 1;
            else $display("FAIL long encrypt vector %0d (n_ad=%0d n_pt=%0d)", v, n_ad, n_pt);
            if (!dec_bad) dec_pass = dec_pass + 1;
            else $display("FAIL long decrypt vector %0d (n_ad=%0d n_pt=%0d)", v, n_ad, n_pt);
        end

        $display("PASSED long_encrypt %0d/%0d (up to %0d blocks)", enc_pass, n_vec, blocks_max);
        $display("PASSED long_decrypt %0d/%0d", dec_pass, n_vec);
        if (enc_pass == n_vec && dec_pass == n_vec && n_vec > 0)
            $display("PASSED ALL");
        else
            $display("FAILED (see FAIL lines above)");
        $finish;
    end

endmodule
