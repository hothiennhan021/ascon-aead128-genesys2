// Directed testbench: drives ascon_aead_fsm through every NIST KAT
// vector in vectors/LWC_AEAD_KAT_128_128.txt, comparing against the
// vector's own published CT/tag fields -- ground truth is the NIST
// file, not model/ascon_model.py.
//
// tb/directed/kat_128_128.hex is a fixed-width $readmemh reformatting
// of that KAT file (see the generator note at the top of the .hex
// file's companion script): per vector it gives already-chunked
// 16-byte AD/PT blocks (raw bytes, zero-filled, NOT pre-padded -- the
// 0x01 pad marker is inserted by the DUT itself via valid_bytes/last,
// so this testbench genuinely exercises the RTL's padding logic) plus
// the vector's own CT bytes and tag, unmodified.
//
// Coverage:
//   1. Encrypt every vector, compare ct+tag against the KAT file.
//   2. Decrypt every vector with the correct CT+tag, compare the
//      recovered plaintext against the original PT field.
//   3/4/5. Negative tests: flip one bit in ciphertext / tag / AD and
//      confirm tag_fail asserts, and that the DUT never reveals the
//      final PROC_TEXT block's DOUT (neither at the block's own
//      PROC_TEXT command nor, on failure, after FINAL) -- per
//      docs/spec.md 8.5.

`timescale 1ns/1ps

module tb_aead;

    localparam OP_INIT       = 3'd1;
    localparam OP_PROC_AD    = 3'd2;
    localparam OP_PROC_TEXT  = 3'd3;
    localparam OP_FINAL      = 3'd4;

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

    localparam VEC_WORDS = 41;
    localparam N_VEC     = 1089;
    localparam MEM_WORDS = VEC_WORDS * N_VEC;

    reg [63:0] mem [0:MEM_WORDS-1];

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

    reg [127:0] captured_dout;
    reg         captured_dout_seen;
    reg [127:0] captured_tag;
    reg         captured_tag_seen;

    // op, last, valid_bytes, din, mode
    task issue_cmd;
        input [2:0]   op;
        input         lst;
        input [4:0]   vb;
        input [127:0] d;
        input         md;
        begin
            captured_dout_seen = 1'b0;
            captured_tag_seen  = 1'b0;
            @(negedge clk);
            opcode_r = op;
            last_r   = lst;
            mode_r   = md;
            vbytes_r = vb;
            din_r    = d;
            start_r  = 1'b1;
            @(negedge clk);
            start_r = 1'b0;
            while (!done_o) begin
                if (dout_valid_o) begin
                    captured_dout      = dout_o;
                    captured_dout_seen = 1'b1;
                end
                if (tag_valid_o) begin
                    captured_tag      = tag_o;
                    captured_tag_seen = 1'b1;
                end
                @(negedge clk);
            end
            if (dout_valid_o) begin
                captured_dout      = dout_o;
                captured_dout_seen = 1'b1;
            end
            if (tag_valid_o) begin
                captured_tag      = tag_o;
                captured_tag_seen = 1'b1;
            end
        end
    endtask

    // ================================================================
    // 1. Encrypt every vector, compare ct+tag against the KAT file.
    // ================================================================

    integer vec, base, j;
    integer count, n_ad, n_pt, ad_len, pt_len;
    integer errors, vec_pass;
    integer first_fail_count, first_fail_adlen, first_fail_ptlen;
    reg     vector_failed;
    reg [4:0]   vb;
    reg [127:0] exp_ct, exp_tag;

    task run_encrypt_vector;
        input integer v;
        begin
            base   = v * VEC_WORDS;
            count  = mem[base+0];
            key_r   = { mem[base+2], mem[base+1] };
            nonce_r = { mem[base+4], mem[base+3] };
            n_ad   = mem[base+5];
            n_pt   = mem[base+6];
            ad_len = mem[base+7];
            pt_len = mem[base+8];
            vector_failed = 1'b0;

            issue_cmd(OP_INIT, 1'b0, 5'd0, 128'h0, 1'b0);

            for (j = 0; j < n_ad; j = j + 1) begin
                issue_cmd(OP_PROC_AD,
                           mem[base+9+j*4+2][0],
                           mem[base+9+j*4+3][4:0],
                           { mem[base+9+j*4+1], mem[base+9+j*4+0] }, 1'b0);
            end

            for (j = 0; j < n_pt; j = j + 1) begin
                vb = mem[base+21+j*4+3][4:0];
                issue_cmd(OP_PROC_TEXT,
                           mem[base+21+j*4+2][0],
                           vb,
                           { mem[base+21+j*4+1], mem[base+21+j*4+0] }, 1'b0);

                exp_ct = { mem[base+34+j*2], mem[base+33+j*2] };
                if (!captured_dout_seen ||
                    ((captured_dout & byte_mask(vb)) !== (exp_ct & byte_mask(vb))))
                    vector_failed = 1'b1;
            end

            issue_cmd(OP_FINAL, 1'b0, 5'd0, 128'h0, 1'b0);
            exp_tag = { mem[base+40], mem[base+39] };
            if (!captured_tag_seen || (captured_tag !== exp_tag))
                vector_failed = 1'b1;

            if (vector_failed) begin
                errors = errors + 1;
                if (first_fail_count < 0) begin
                    first_fail_count = count;
                    first_fail_adlen = ad_len;
                    first_fail_ptlen = pt_len;
                    $display("FAIL encrypt Count=%0d AD_len=%0d PT_len=%0d",
                              first_fail_count, first_fail_adlen, first_fail_ptlen);
                end
            end else begin
                vec_pass = vec_pass + 1;
            end
        end
    endtask

    // ================================================================
    // 2..5. Decrypt direction: correctness + negative tests.
    //
    // corrupt_kind: 0 = clean decrypt (correctness check)
    //               1 = flip 1 bit in the first CT block fed as din
    //               2 = flip 1 bit in tag_in
    //               3 = flip 1 bit in the first AD block fed as din
    // The flipped bit is always bit 0 of block index 0: for a
    // single-block phase valid_bytes >= 1 so byte 0 is always real
    // data, and for a multi-block phase block 0 is never the last
    // block so the DUT XORs/overwrites it unconditionally -- the flip
    // is guaranteed to actually change the absorbed/decrypted value
    // in every case this KAT file exercises (AD/PT length 0..32).
    // ================================================================

    integer dec_j, dec_n_ad, dec_n_pt, dec_base;
    reg [127:0] dec_din, dec_exp_pt;
    reg [4:0]   dec_vb;
    reg         dec_last;
    reg [127:0] dec_tag_in;

    reg dec_tag_fail;
    reg dec_last_proc_revealed;
    reg dec_final_revealed;
    reg dec_final_pt_ok;
    reg dec_mismatch;

    task do_decrypt;
        input integer v;
        input integer corrupt_kind;
        begin
            dec_base  = v * VEC_WORDS;
            key_r     = { mem[dec_base+2], mem[dec_base+1] };
            nonce_r   = { mem[dec_base+4], mem[dec_base+3] };
            dec_n_ad  = mem[dec_base+5];
            dec_n_pt  = mem[dec_base+6];
            dec_tag_in = { mem[dec_base+40], mem[dec_base+39] };
            if (corrupt_kind == 2)
                dec_tag_in = dec_tag_in ^ 128'h1;

            issue_cmd(OP_INIT, 1'b0, 5'd0, 128'h0, 1'b1);

            for (dec_j = 0; dec_j < dec_n_ad; dec_j = dec_j + 1) begin
                dec_din = { mem[dec_base+9+dec_j*4+1], mem[dec_base+9+dec_j*4+0] };
                if (corrupt_kind == 3 && dec_j == 0)
                    dec_din = dec_din ^ 128'h1;
                issue_cmd(OP_PROC_AD,
                           mem[dec_base+9+dec_j*4+2][0],
                           mem[dec_base+9+dec_j*4+3][4:0],
                           dec_din, 1'b1);
            end

            dec_mismatch           = 1'b0;
            dec_last_proc_revealed = 1'b0;

            for (dec_j = 0; dec_j < dec_n_pt; dec_j = dec_j + 1) begin
                dec_last = mem[dec_base+21+dec_j*4+2][0];
                dec_vb   = mem[dec_base+21+dec_j*4+3][4:0];
                dec_din  = { mem[dec_base+34+dec_j*2], mem[dec_base+33+dec_j*2] }; // CT block

                if (corrupt_kind == 1 && dec_j == 0)
                    dec_din = dec_din ^ 128'h1;

                issue_cmd(OP_PROC_TEXT, dec_last, dec_vb, dec_din, 1'b1);

                if (dec_last) begin
                    dec_last_proc_revealed = captured_dout_seen;
                end else if (corrupt_kind == 0 || corrupt_kind == 2) begin
                    // corrupted CT/AD in block 0 poisons every later
                    // block's recovered plaintext -- only meaningful
                    // to compare non-last blocks when the corruption
                    // (if any) cannot have reached them yet: clean
                    // decrypt, or a tag-only corruption that never
                    // touches the rate/permutation datapath at all.
                    dec_exp_pt = { mem[dec_base+21+dec_j*4+1], mem[dec_base+21+dec_j*4+0] };
                    if (!captured_dout_seen ||
                        ((captured_dout & byte_mask(5'd16)) !== (dec_exp_pt & byte_mask(5'd16))))
                        dec_mismatch = 1'b1;
                end
            end

            tag_in_r = dec_tag_in;
            issue_cmd(OP_FINAL, 1'b0, 5'd0, 128'h0, 1'b1);

            dec_tag_fail       = tag_fail_o;
            dec_final_revealed = captured_dout_seen;

            if (dec_final_revealed) begin
                dec_j  = dec_n_pt - 1;
                dec_vb = mem[dec_base+21+dec_j*4+3][4:0];
                dec_exp_pt = { mem[dec_base+21+dec_j*4+1], mem[dec_base+21+dec_j*4+0] };
                dec_final_pt_ok =
                    ((captured_dout & byte_mask(dec_vb)) === (dec_exp_pt & byte_mask(dec_vb)));
            end else begin
                dec_final_pt_ok = 1'b0;
            end
        end
    endtask

    integer dec_errors, dec_pass_count;
    integer dec_first_fail_count;

    integer ctflip_tested, ctflip_pass, ctflip_first_fail;
    integer tagflip_tested, tagflip_pass, tagflip_first_fail;
    integer adflip_tested, adflip_pass, adflip_first_fail;

    localparam NEG_STRIDE = 19; // ~58 vectors, well over the required 50,
                                // spread across the full AD/PT length range

    initial begin
        $readmemh("tb/directed/kat_128_128.hex", mem);

        clk      = 1'b0;
        rst_n    = 1'b0;
        start_r  = 1'b0;
        opcode_r = 3'd0;
        last_r   = 1'b0;
        mode_r   = 1'b0;
        vbytes_r = 5'd0;
        key_r    = 128'h0;
        nonce_r  = 128'h0;
        din_r    = 128'h0;
        tag_in_r = 128'h0;

        errors           = 0;
        vec_pass         = 0;
        first_fail_count = -1;

        dec_errors           = 0;
        dec_pass_count       = 0;
        dec_first_fail_count = -1;

        ctflip_tested = 0; ctflip_pass = 0; ctflip_first_fail = -1;
        tagflip_tested = 0; tagflip_pass = 0; tagflip_first_fail = -1;
        adflip_tested = 0; adflip_pass = 0; adflip_first_fail = -1;

        @(negedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        // ---- 1. encrypt every vector -----------------------------------
        for (vec = 0; vec < N_VEC; vec = vec + 1)
            run_encrypt_vector(vec);
        $display("PASSED encrypt %0d/%0d", vec_pass, N_VEC);

        // ---- 2. decrypt every vector, correct CT+tag --------------------
        for (vec = 0; vec < N_VEC; vec = vec + 1) begin
            base   = vec * VEC_WORDS;
            count  = mem[base+0];
            ad_len = mem[base+7];
            pt_len = mem[base+8];

            do_decrypt(vec, 0);

            if (dec_mismatch || dec_tag_fail || dec_last_proc_revealed ||
                !dec_final_revealed || !dec_final_pt_ok) begin
                dec_errors = dec_errors + 1;
                if (dec_first_fail_count < 0) begin
                    dec_first_fail_count = count;
                    $display("FAIL decrypt Count=%0d AD_len=%0d PT_len=%0d",
                              count, ad_len, pt_len);
                end
            end else begin
                dec_pass_count = dec_pass_count + 1;
            end
        end
        $display("PASSED decrypt %0d/%0d", dec_pass_count, N_VEC);

        // ---- 3/4/5. negative tests --------------------------------------
        for (vec = 0; vec < N_VEC; vec = vec + NEG_STRIDE) begin
            base   = vec * VEC_WORDS;
            count  = mem[base+0];
            ad_len = mem[base+7];
            pt_len = mem[base+8];

            if (pt_len > 0) begin
                ctflip_tested = ctflip_tested + 1;
                do_decrypt(vec, 1);
                if (dec_tag_fail && !dec_last_proc_revealed && !dec_final_revealed) begin
                    ctflip_pass = ctflip_pass + 1;
                end else if (ctflip_first_fail < 0) begin
                    ctflip_first_fail = count;
                    $display("FAIL ct_flip Count=%0d AD_len=%0d PT_len=%0d tag_fail=%0d last_proc_revealed=%0d final_revealed=%0d",
                              count, ad_len, pt_len,
                              dec_tag_fail, dec_last_proc_revealed, dec_final_revealed);
                end
            end

            tagflip_tested = tagflip_tested + 1;
            do_decrypt(vec, 2);
            if (dec_tag_fail && !dec_last_proc_revealed && !dec_final_revealed && !dec_mismatch) begin
                tagflip_pass = tagflip_pass + 1;
            end else if (tagflip_first_fail < 0) begin
                tagflip_first_fail = count;
                $display("FAIL tag_flip Count=%0d AD_len=%0d PT_len=%0d tag_fail=%0d last_proc_revealed=%0d final_revealed=%0d mismatch=%0d",
                          count, ad_len, pt_len,
                          dec_tag_fail, dec_last_proc_revealed, dec_final_revealed, dec_mismatch);
            end

            if (ad_len > 0) begin
                adflip_tested = adflip_tested + 1;
                do_decrypt(vec, 3);
                if (dec_tag_fail && !dec_last_proc_revealed && !dec_final_revealed) begin
                    adflip_pass = adflip_pass + 1;
                end else if (adflip_first_fail < 0) begin
                    adflip_first_fail = count;
                    $display("FAIL ad_flip Count=%0d AD_len=%0d PT_len=%0d tag_fail=%0d last_proc_revealed=%0d final_revealed=%0d",
                              count, ad_len, pt_len,
                              dec_tag_fail, dec_last_proc_revealed, dec_final_revealed);
                end
            end
        end

        $display("PASSED ct_flip %0d/%0d (min 50 required)", ctflip_pass, ctflip_tested);
        $display("PASSED tag_flip %0d/%0d", tagflip_pass, tagflip_tested);
        $display("PASSED ad_flip %0d/%0d", adflip_pass, adflip_tested);

        if (errors == 0 && dec_errors == 0 &&
            ctflip_pass == ctflip_tested && ctflip_tested >= 50 &&
            tagflip_pass == tagflip_tested &&
            adflip_pass == adflip_tested)
            $display("PASSED ALL");
        else
            $display("FAILED (see FAIL lines above)");

        $finish;
    end

endmodule
