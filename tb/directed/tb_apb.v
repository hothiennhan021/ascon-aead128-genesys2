// Directed testbench for rtl/ip/ascon_apb.v: a small APB master BFM
// drives the same NIST KAT vectors (vectors/LWC_AEAD_KAT_128_128.txt,
// via the tb/directed/kat_128_128.hex reformatting already used by
// tb_aead.v) through the bus -- register writes/reads instead of
// wiring straight into ascon_aead_fsm -- comparing ct+tag against the
// vector's own CT field.
//
// Extra checks beyond tb_aead.v:
//   - reading KEY0..3 always returns 0 (docs/spec.md 7)
//   - writing CMD while STATUS.busy=1 is silently ignored (no
//     pslverr, no disruption to the operation already in flight)
//   - PROC_TEXT issued with DIN under-written (only 2/4 words):
//     rejected, pslverr=1, core never leaves IDLE
//   - DIN over-written (6 consecutive word writes to the 4 DIN
//     addresses before the command): last write per word offset
//     wins, no pslverr, and processing still produces the correct
//     ciphertext (docs/spec.md 9.3 din_count semantics)
//   - reads/writes to unmapped (0x70, 0xFC) and non-word-aligned
//     (0x11) offsets: silently ignored on write, read back as 0,
//     no pslverr, no observable side effect on STATUS
//   - presetn toggled mid-operation (while STATUS.busy=1): core
//     must land back in a clean IDLE (STATUS==0), and the very next
//     encryption must still produce a correct result
//   - two full encryptions run back-to-back with no reset between
//     them: second must not inherit any state from the first

`timescale 1ns/1ps

module tb_apb;

    localparam OP_INIT       = 3'd1;
    localparam OP_PROC_AD    = 3'd2;
    localparam OP_PROC_TEXT  = 3'd3;
    localparam OP_FINAL      = 3'd4;

    localparam ADDR_CMD    = 8'h00;
    localparam ADDR_STATUS = 8'h04;
    localparam ADDR_KEY0   = 8'h10;
    localparam ADDR_NONCE0 = 8'h20;
    localparam ADDR_DIN0   = 8'h30;
    localparam ADDR_DOUT0  = 8'h40;
    localparam ADDR_TAG0   = 8'h50;
    localparam ADDR_TAGIN0 = 8'h60;

    reg pclk, presetn;
    reg        psel, penable, pwrite;
    reg [7:0]  paddr;
    reg [31:0] pwdata;
    wire [31:0] prdata;
    wire        pready, pslverr;

    ascon_apb dut (
        .pclk    (pclk),
        .presetn (presetn),
        .psel    (psel),
        .penable (penable),
        .pwrite  (pwrite),
        .paddr   (paddr),
        .pwdata  (pwdata),
        .prdata  (prdata),
        .pready  (pready),
        .pslverr (pslverr)
    );

    // Passive protocol monitor -- pure Verilog-2001, no SVA (see
    // tb/sva/apb_checker.v). Watches the same bus signals the BFM
    // drives into `dut`; never influences the DUT.
    wire [31:0] apb_checker_violations;

    apb_checker u_apb_checker (
        .pclk            (pclk),
        .presetn         (presetn),
        .psel            (psel),
        .penable         (penable),
        .pwrite          (pwrite),
        .paddr           (paddr),
        .pwdata          (pwdata),
        .prdata          (prdata),
        .pready          (pready),
        .violation_count (apb_checker_violations)
    );

    always #5 pclk = ~pclk;

    reg [31:0] last_pslverr_capture;

    task apb_write;
        input [7:0]  addr;
        input [31:0] data;
        begin
            @(negedge pclk);
            psel    = 1'b1;
            penable = 1'b0;
            pwrite  = 1'b1;
            paddr   = addr;
            pwdata  = data;
            @(negedge pclk);
            penable = 1'b1;
            @(negedge pclk);
            last_pslverr_capture = pslverr;
            psel    = 1'b0;
            penable = 1'b0;
            pwrite  = 1'b0;
        end
    endtask

    task apb_read;
        input  [7:0]  addr;
        output [31:0] data;
        begin
            @(negedge pclk);
            psel    = 1'b1;
            penable = 1'b0;
            pwrite  = 1'b0;
            paddr   = addr;
            @(negedge pclk);
            penable = 1'b1;
            @(negedge pclk);
            data = prdata;
            psel    = 1'b0;
            penable = 1'b0;
        end
    endtask

    function [31:0] build_cmd;
        input [2:0] op;
        input       lst;
        input       md;
        input [4:0] vb;
        reg [31:0] w;
        begin
            w = 32'h0;
            w[2:0]  = op;
            w[3]    = lst;
            w[4]    = md;
            w[12:8] = vb;
            build_cmd = w;
        end
    endfunction

    // wait for STATUS.done, return the STATUS word from the read that
    // first showed it set (so dout_valid/tag_valid/tag_fail from the
    // same word are consistent with "done" without an extra read)
    reg [31:0] status_word;

    task wait_done;
        begin
            status_word = 32'h0;
            while (!status_word[1])
                apb_read(ADDR_STATUS, status_word);
        end
    endtask

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

    integer vec, base, j;
    integer count, n_ad, n_pt, ad_len, pt_len;
    integer errors, vec_pass;
    integer first_fail_count, first_fail_adlen, first_fail_ptlen;
    reg     vector_failed;
    reg [4:0]   vb;
    reg [127:0] key_v, nonce_v, din_v, exp_ct, exp_tag, captured_dout, captured_tag;
    reg [31:0]  rd;
    integer     disrupt_this_vector;

    task write_key_nonce;
        begin
            apb_write(ADDR_KEY0+8'h00, key_v[31:0]);
            apb_write(ADDR_KEY0+8'h04, key_v[63:32]);
            apb_write(ADDR_KEY0+8'h08, key_v[95:64]);
            apb_write(ADDR_KEY0+8'h0C, key_v[127:96]);
            apb_write(ADDR_NONCE0+8'h00, nonce_v[31:0]);
            apb_write(ADDR_NONCE0+8'h04, nonce_v[63:32]);
            apb_write(ADDR_NONCE0+8'h08, nonce_v[95:64]);
            apb_write(ADDR_NONCE0+8'h0C, nonce_v[127:96]);
        end
    endtask

    task write_din;
        input [127:0] d;
        begin
            apb_write(ADDR_DIN0+8'h00, d[31:0]);
            apb_write(ADDR_DIN0+8'h04, d[63:32]);
            apb_write(ADDR_DIN0+8'h08, d[95:64]);
            apb_write(ADDR_DIN0+8'h0C, d[127:96]);
        end
    endtask

    task read_dout;
        output [127:0] d;
        begin
            apb_read(ADDR_DOUT0+8'h00, rd); d[31:0]   = rd;
            apb_read(ADDR_DOUT0+8'h04, rd); d[63:32]  = rd;
            apb_read(ADDR_DOUT0+8'h08, rd); d[95:64]  = rd;
            apb_read(ADDR_DOUT0+8'h0C, rd); d[127:96] = rd;
        end
    endtask

    task read_tag;
        output [127:0] d;
        begin
            apb_read(ADDR_TAG0+8'h00, rd); d[31:0]   = rd;
            apb_read(ADDR_TAG0+8'h04, rd); d[63:32]  = rd;
            apb_read(ADDR_TAG0+8'h08, rd); d[95:64]  = rd;
            apb_read(ADDR_TAG0+8'h0C, rd); d[127:96] = rd;
        end
    endtask

    // "ghi lenh khi busy bi bo qua": right after the INIT command is
    // accepted (core is now busy for the 14-cycle p12), fire a bogus
    // CMD write and confirm: no pslverr, STATUS.busy was really 1 at
    // that moment, and the ongoing operation is unaffected.
    integer busy_test_ok, busy_test_ran;

    // "ghi thua DIN": before the real 4-word write for the disrupted
    // vector's first PT block, fire 2 bogus writes to DIN0/DIN1 (6
    // consecutive DIN-address writes total). Last write per word
    // offset must win with no pslverr along the way; the existing
    // ciphertext check below then proves the extra writes didn't
    // corrupt anything.
    integer dinover_test_ran;
    reg     dinover_bad_pslverr;
    integer dinover_test_ok;

    task run_vector;
        input integer v;
        input do_busy_disrupt;
        input do_din_overwrite_disrupt;
        begin
            base    = v * VEC_WORDS;
            count   = mem[base+0];
            key_v   = { mem[base+2], mem[base+1] };
            nonce_v = { mem[base+4], mem[base+3] };
            n_ad    = mem[base+5];
            n_pt    = mem[base+6];
            ad_len  = mem[base+7];
            pt_len  = mem[base+8];
            vector_failed = 1'b0;

            write_key_nonce;
            apb_write(ADDR_CMD, build_cmd(OP_INIT, 1'b0, 1'b0, 5'd0));

            if (do_busy_disrupt) begin
                busy_test_ran = 1;
                apb_read(ADDR_STATUS, rd);
                apb_write(ADDR_CMD, build_cmd(OP_INIT, 1'b0, 1'b0, 5'd0)); // bogus write while busy
                if (rd[0] === 1'b1 && last_pslverr_capture === 1'b0)
                    busy_test_ok = 1;
                else
                    busy_test_ok = 0;
            end

            wait_done;

            for (j = 0; j < n_ad; j = j + 1) begin
                write_din({ mem[base+9+j*4+1], mem[base+9+j*4+0] });
                apb_write(ADDR_CMD, build_cmd(OP_PROC_AD,
                                               mem[base+9+j*4+2][0],
                                               1'b0,
                                               mem[base+9+j*4+3][4:0]));
                wait_done;
            end

            for (j = 0; j < n_pt; j = j + 1) begin
                vb = mem[base+21+j*4+3][4:0];
                if (do_din_overwrite_disrupt && j == 0) begin
                    dinover_test_ran = 1;
                    apb_write(ADDR_DIN0+8'h00, 32'hDEADBEEF);
                    if (last_pslverr_capture !== 1'b0) dinover_bad_pslverr = 1'b1;
                    apb_write(ADDR_DIN0+8'h04, 32'h5A5A5A5A);
                    if (last_pslverr_capture !== 1'b0) dinover_bad_pslverr = 1'b1;
                end
                write_din({ mem[base+21+j*4+1], mem[base+21+j*4+0] });
                apb_write(ADDR_CMD, build_cmd(OP_PROC_TEXT,
                                               mem[base+21+j*4+2][0],
                                               1'b0,
                                               vb));
                wait_done;

                if (status_word[2]) begin
                    read_dout(captured_dout);
                    exp_ct = { mem[base+34+j*2], mem[base+33+j*2] };
                    if ((captured_dout & byte_mask(vb)) !== (exp_ct & byte_mask(vb)))
                        vector_failed = 1'b1;
                end else begin
                    vector_failed = 1'b1;
                end
            end

            apb_write(ADDR_CMD, build_cmd(OP_FINAL, 1'b0, 1'b0, 5'd0));
            wait_done;
            if (status_word[3]) begin
                read_tag(captured_tag);
                exp_tag = { mem[base+40], mem[base+39] };
                if (captured_tag !== exp_tag)
                    vector_failed = 1'b1;
            end else begin
                vector_failed = 1'b1;
            end

            if (do_din_overwrite_disrupt)
                dinover_test_ok = !dinover_bad_pslverr && !vector_failed;

            if (vector_failed) begin
                errors = errors + 1;
                if (first_fail_count < 0) begin
                    first_fail_count = count;
                    first_fail_adlen = ad_len;
                    first_fail_ptlen = pt_len;
                    $display("FAIL apb Count=%0d AD_len=%0d PT_len=%0d",
                              count, ad_len, pt_len);
                end
            end else begin
                vec_pass = vec_pass + 1;
            end
        end
    endtask

    integer key_read_errors;

    task check_key_reads_zero;
        begin
            apb_write(ADDR_KEY0+8'h00, 32'hDEADBEEF);
            apb_write(ADDR_KEY0+8'h04, 32'h12345678);
            apb_write(ADDR_KEY0+8'h08, 32'hCAFEBABE);
            apb_write(ADDR_KEY0+8'h0C, 32'hFFFFFFFF);
            apb_read(ADDR_KEY0+8'h00, rd); if (rd !== 32'h0) key_read_errors = key_read_errors + 1;
            apb_read(ADDR_KEY0+8'h04, rd); if (rd !== 32'h0) key_read_errors = key_read_errors + 1;
            apb_read(ADDR_KEY0+8'h08, rd); if (rd !== 32'h0) key_read_errors = key_read_errors + 1;
            apb_read(ADDR_KEY0+8'h0C, rd); if (rd !== 32'h0) key_read_errors = key_read_errors + 1;
        end
    endtask

    // "ghi thieu DIN": write only 2/4 words then issue PROC_TEXT --
    // must be rejected (pslverr=1), core must never leave IDLE, and
    // the sticky done bit left over from the prior INIT must be
    // untouched (proves the write was never accepted).
    integer dinunder_test_ran, dinunder_test_ok;

    task test_din_underflow;
        reg [31:0] status_before, status_after;
        begin
            dinunder_test_ran = 1;
            key_v   = 128'h00112233445566778899AABBCCDDEEFF;
            nonce_v = 128'hFFEEDDCCBBAA99887766554433221100;
            write_key_nonce;
            apb_write(ADDR_CMD, build_cmd(OP_INIT, 1'b0, 1'b0, 5'd0));
            wait_done;
            apb_read(ADDR_STATUS, status_before);

            apb_write(ADDR_DIN0+8'h00, 32'h11111111);
            apb_write(ADDR_DIN0+8'h04, 32'h22222222);
            apb_read(ADDR_STATUS, rd);

            if (rd[5] !== 1'b0) begin
                dinunder_test_ok = 0; // din_full should not be set with only 2/4 words
            end else begin
                apb_write(ADDR_CMD, build_cmd(OP_PROC_TEXT, 1'b1, 1'b0, 5'd16));
                apb_read(ADDR_STATUS, status_after);
                dinunder_test_ok = (last_pslverr_capture === 1'b1) &&
                                   (status_after[0] === 1'b0) &&
                                   (status_after[1] === status_before[1]);
            end
        end
    endtask

    // Unmapped (0x70, 0xFC) and non-word-aligned (0x11) offsets: write
    // must be silently ignored (no pslverr), read back must be 0, and
    // STATUS must be unaffected by the write.
    integer unmapped_errors;

    task check_addr_ignored;
        input [7:0]  addr;
        input [31:0] wval;
        reg [31:0] status_before, status_after, rdval;
        begin
            apb_read(ADDR_STATUS, status_before);
            apb_write(addr, wval);
            if (last_pslverr_capture !== 1'b0) unmapped_errors = unmapped_errors + 1;
            apb_read(addr, rdval);
            if (rdval !== 32'h0) unmapped_errors = unmapped_errors + 1;
            apb_read(ADDR_STATUS, status_after);
            if (status_after !== status_before) unmapped_errors = unmapped_errors + 1;
        end
    endtask

    // Reset asserted while the core is mid-permutation (busy after an
    // accepted INIT): must land back in a clean IDLE (STATUS==0), and
    // the very next encryption (vector 0, run through the normal
    // run_vector path) must still be correct. The run_vector call
    // here is scratch verification only -- counters are saved and
    // restored so vector 0 is still counted exactly once by the main
    // loop below.
    integer reset_mid_op_ok;

    task test_reset_mid_op;
        integer errs_save, pass_save;
        reg [31:0] status_mid, status_after_reset;
        begin
            reset_mid_op_ok = 1;
            key_v   = { mem[0*VEC_WORDS+2], mem[0*VEC_WORDS+1] };
            nonce_v = { mem[0*VEC_WORDS+4], mem[0*VEC_WORDS+3] };
            write_key_nonce;
            apb_write(ADDR_CMD, build_cmd(OP_INIT, 1'b0, 1'b0, 5'd0));

            apb_read(ADDR_STATUS, status_mid);
            if (status_mid[0] !== 1'b1)
                reset_mid_op_ok = 0; // core should be busy mid-p12

            repeat (3) @(negedge pclk);
            presetn = 1'b0;
            repeat (2) @(negedge pclk);
            presetn = 1'b1;
            @(negedge pclk);

            apb_read(ADDR_STATUS, status_after_reset);
            if (status_after_reset !== 32'h0)
                reset_mid_op_ok = 0; // busy/done/dout_valid/tag_valid/tag_fail/din_full all clear

            errs_save = errors;
            pass_save = vec_pass;
            run_vector(0, 1'b0, 1'b0);
            if (errors !== errs_save)
                reset_mid_op_ok = 0;
            errors   = errs_save;
            vec_pass = pass_save;
        end
    endtask

    // Two full encryptions back-to-back with no reset in between:
    // vec 500/501 (both non-trivial AD+PT) are captured out of the
    // main loop below, which already runs every vector with presetn
    // held high throughout -- this just gives the requirement its own
    // named pass/fail line.
    integer no_reset_a_failed, no_reset_b_failed;

    initial begin
        $readmemh("tb/directed/kat_128_128.hex", mem);

        pclk    = 1'b0;
        presetn = 1'b0;
        psel    = 1'b0;
        penable = 1'b0;
        pwrite  = 1'b0;
        paddr   = 8'h0;
        pwdata  = 32'h0;

        errors             = 0;
        vec_pass           = 0;
        first_fail_count   = -1;
        key_read_errors    = 0;
        busy_test_ran      = 0;
        busy_test_ok       = 0;
        dinover_test_ran   = 0;
        dinover_bad_pslverr = 1'b0;
        dinover_test_ok    = 0;
        dinunder_test_ran  = 0;
        dinunder_test_ok   = 0;
        unmapped_errors    = 0;
        reset_mid_op_ok    = 0;
        no_reset_a_failed  = 1'b1;
        no_reset_b_failed  = 1'b1;

        @(negedge pclk);
        @(negedge pclk);
        presetn = 1'b1;

        check_key_reads_zero;
        if (key_read_errors == 0)
            $display("PASSED key_read_zero 4/4");
        else
            $display("FAIL key_read_zero %0d bad word(s)", key_read_errors);

        test_din_underflow;
        if (dinunder_test_ran && dinunder_test_ok)
            $display("PASSED din_underflow_rejected 1/1");
        else
            $display("FAIL din_underflow_rejected (ran=%0d ok=%0d)", dinunder_test_ran, dinunder_test_ok);

        check_addr_ignored(8'h70, 32'hA5A5A5A5);
        check_addr_ignored(8'hFC, 32'h5A5A5A5A);
        check_addr_ignored(8'h11, 32'hDEADBEEF);
        if (unmapped_errors == 0)
            $display("PASSED unmapped_misaligned_addr 3/3");
        else
            $display("FAIL unmapped_misaligned_addr %0d bad check(s)", unmapped_errors);

        test_reset_mid_op;
        if (reset_mid_op_ok)
            $display("PASSED reset_mid_operation 1/1");
        else
            $display("FAIL reset_mid_operation");

        for (vec = 0; vec < N_VEC; vec = vec + 1) begin
            run_vector(vec, (vec == 0), (vec == 165));
            if (vec == 500) no_reset_a_failed = vector_failed;
            if (vec == 501) no_reset_b_failed = vector_failed;
        end

        if (busy_test_ran && busy_test_ok)
            $display("PASSED busy_write_ignored 1/1");
        else
            $display("FAIL busy_write_ignored (ran=%0d ok=%0d)", busy_test_ran, busy_test_ok);

        if (dinover_test_ran && dinover_test_ok)
            $display("PASSED din_overwrite_deterministic 1/1");
        else
            $display("FAIL din_overwrite_deterministic (ran=%0d ok=%0d)", dinover_test_ran, dinover_test_ok);

        if (!no_reset_a_failed && !no_reset_b_failed)
            $display("PASSED back_to_back_no_reset 2/2");
        else
            $display("FAIL back_to_back_no_reset (vec500_failed=%0d vec501_failed=%0d)",
                      no_reset_a_failed, no_reset_b_failed);

        $display("PASSED apb %0d/%0d", vec_pass, N_VEC);

        u_apb_checker.report_summary;
        if (apb_checker_violations == 0)
            $display("PASSED apb_protocol_checker 0/0");
        else
            $display("FAIL apb_protocol_checker %0d violation(s)", apb_checker_violations);

        if (errors == 0 && key_read_errors == 0 && busy_test_ran && busy_test_ok &&
            dinunder_test_ran && dinunder_test_ok && unmapped_errors == 0 &&
            reset_mid_op_ok && dinover_test_ran && dinover_test_ok &&
            !no_reset_a_failed && !no_reset_b_failed &&
            apb_checker_violations == 0)
            $display("PASSED ALL");
        else
            $display("FAILED (see FAIL lines above)");

        $finish;
    end

endmodule
