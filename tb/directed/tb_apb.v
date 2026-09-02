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

    task run_vector;
        input integer v;
        input do_busy_disrupt;
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

    initial begin
        $readmemh("tb/directed/kat_128_128.hex", mem);

        pclk    = 1'b0;
        presetn = 1'b0;
        psel    = 1'b0;
        penable = 1'b0;
        pwrite  = 1'b0;
        paddr   = 8'h0;
        pwdata  = 32'h0;

        errors           = 0;
        vec_pass         = 0;
        first_fail_count = -1;
        key_read_errors  = 0;
        busy_test_ran    = 0;
        busy_test_ok     = 0;

        @(negedge pclk);
        @(negedge pclk);
        presetn = 1'b1;

        check_key_reads_zero;
        if (key_read_errors == 0)
            $display("PASSED key_read_zero 4/4");
        else
            $display("FAIL key_read_zero %0d bad word(s)", key_read_errors);

        for (vec = 0; vec < N_VEC; vec = vec + 1)
            run_vector(vec, (vec == 0));

        if (busy_test_ran && busy_test_ok)
            $display("PASSED busy_write_ignored 1/1");
        else
            $display("FAIL busy_write_ignored (ran=%0d ok=%0d)", busy_test_ran, busy_test_ok);

        $display("PASSED apb %0d/%0d", vec_pass, N_VEC);

        if (errors == 0 && key_read_errors == 0 && busy_test_ran && busy_test_ok)
            $display("PASSED ALL");
        else
            $display("FAILED (see FAIL lines above)");

        $finish;
    end

endmodule
