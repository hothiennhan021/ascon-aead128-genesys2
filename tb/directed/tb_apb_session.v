// Directed testbench for rtl/ip/ascon_apb.v, complementing tb_apb.v
// (which only runs ENCRYPT through the bus). Everything here goes
// through the APB register interface, with tb/sva/apb_checker.v
// watching the bus the whole time.
//
//   1. decrypt_kat     : all 1089 KAT vectors decrypted through APB --
//                        non-last blocks correct, last block held until
//                        FINAL, released only on tag OK, bytes past
//                        valid_bytes read as 0, TAG registers stay 0.
//   2. decrypt_neg     : 1-bit tag flip on every 7th vector -- tag_fail=1,
//                        last block never released, TAG registers 0.
//   3. tag_fail_clear  : a new session after a failed decrypt starts with
//                        STATUS.tag_fail=0 (and the checker stays quiet).
//   4. din_mask        : 4 writes to the same DIN word do not make
//                        din_full; 8 writes covering all words do.
//   5. cmd_checks      : reserved opcode, last=1 with valid_bytes>15,
//                        out-of-order commands and mode mismatch are all
//                        rejected with pslverr + STATUS.cmd_err, without
//                        starting the core; the next good command clears
//                        cmd_err.
//   6. busy_write_lock : KEY/NONCE/TAGIN writes while busy are ignored.
//   7. dout_mask       : partial last block -> DOUT bytes >= valid_bytes
//                        are exactly 0.
//   8. soft_reset      : SOFT_RESET ends the session (FINAL rejected
//                        afterwards), clears DOUT/TAG, next session OK.
//   9. din_prewrite    : next block's DIN written while the core is busy
//                        with the current one -- still bit-exact.
//
// The BFM samples pslverr/prdata on the clock edge that completes the
// ACCESS phase, like a real APB master.

`timescale 1ns/1ps

module tb_apb_session;

    localparam OP_NOP        = 3'd0;
    localparam OP_INIT       = 3'd1;
    localparam OP_PROC_AD    = 3'd2;
    localparam OP_PROC_TEXT  = 3'd3;
    localparam OP_FINAL      = 3'd4;
    localparam OP_SOFT_RESET = 3'd7;

    localparam ADDR_CMD    = 8'h00;
    localparam ADDR_STATUS = 8'h04;
    localparam ADDR_KEY0   = 8'h10;
    localparam ADDR_NONCE0 = 8'h20;
    localparam ADDR_DIN0   = 8'h30;
    localparam ADDR_DOUT0  = 8'h40;
    localparam ADDR_TAG0   = 8'h50;
    localparam ADDR_TAGIN0 = 8'h60;

    localparam ST_BUSY = 0, ST_DONE = 1, ST_DOUT_VALID = 2, ST_TAG_VALID = 3,
               ST_TAG_FAIL = 4, ST_DIN_FULL = 5, ST_CMD_ERR = 6;

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
        .pslverr         (pslverr),
        .violation_count (apb_checker_violations)
    );

    always #5 pclk = ~pclk;

    // ---- APB master BFM ------------------------------------------------
    reg last_pslverr;

    task apb_write;
        input [7:0]  addr;
        input [31:0] data;
        begin
            @(negedge pclk);
            psel = 1'b1; penable = 1'b0; pwrite = 1'b1; paddr = addr; pwdata = data;
            @(negedge pclk);
            penable = 1'b1;
            @(posedge pclk);
            last_pslverr = pslverr;
            @(negedge pclk);
            psel = 1'b0; penable = 1'b0; pwrite = 1'b0;
        end
    endtask

    task apb_read;
        input  [7:0]  addr;
        output [31:0] data;
        begin
            @(negedge pclk);
            psel = 1'b1; penable = 1'b0; pwrite = 1'b0; paddr = addr;
            @(negedge pclk);
            penable = 1'b1;
            @(posedge pclk);
            data = prdata;
            @(negedge pclk);
            psel = 1'b0; penable = 1'b0;
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

    reg [31:0]  st, rd;

    task wait_done;
        begin
            st = 32'h0;
            while (!st[ST_DONE])
                apb_read(ADDR_STATUS, st);
        end
    endtask

    task write128;
        input [7:0]   base_addr;
        input [127:0] v;
        begin
            apb_write(base_addr + 8'h00, v[31:0]);
            apb_write(base_addr + 8'h04, v[63:32]);
            apb_write(base_addr + 8'h08, v[95:64]);
            apb_write(base_addr + 8'h0C, v[127:96]);
        end
    endtask

    task read128;
        input  [7:0]   base_addr;
        output [127:0] v;
        begin
            apb_read(base_addr + 8'h00, rd); v[31:0]   = rd;
            apb_read(base_addr + 8'h04, rd); v[63:32]  = rd;
            apb_read(base_addr + 8'h08, rd); v[95:64]  = rd;
            apb_read(base_addr + 8'h0C, rd); v[127:96] = rd;
        end
    endtask

    // ---- KAT memory (same layout as tb_apb.v / tb_aead.v) -------------
    localparam VEC_WORDS = 41;
    localparam N_VEC     = 1089;
    localparam MEM_WORDS = VEC_WORDS * N_VEC;

    reg [63:0] mem [0:MEM_WORDS-1];

    integer base, j, n_ad, n_pt;
    reg [127:0] key_v, nonce_v, blk, exp_blk, got, exp_tag, zero128;
    reg [4:0]   vb;
    reg         lst;

    function [127:0] ad_blk;  input integer b; input integer i;
        ad_blk = { mem[b+9+i*4+1], mem[b+9+i*4+0] }; endfunction
    function        ad_last; input integer b; input integer i;
        ad_last = mem[b+9+i*4+2][0]; endfunction
    function [4:0]  ad_vb;   input integer b; input integer i;
        ad_vb = mem[b+9+i*4+3][4:0]; endfunction
    function [127:0] pt_blk;  input integer b; input integer i;
        pt_blk = { mem[b+21+i*4+1], mem[b+21+i*4+0] }; endfunction
    function        pt_last; input integer b; input integer i;
        pt_last = mem[b+21+i*4+2][0]; endfunction
    function [4:0]  pt_vb;   input integer b; input integer i;
        pt_vb = mem[b+21+i*4+3][4:0]; endfunction
    function [127:0] ct_blk;  input integer b; input integer i;
        ct_blk = { mem[b+34+i*2], mem[b+33+i*2] }; endfunction

    task load_vector;
        input integer v;
        begin
            base    = v * VEC_WORDS;
            key_v   = { mem[base+2], mem[base+1] };
            nonce_v = { mem[base+4], mem[base+3] };
            n_ad    = mem[base+5];
            n_pt    = mem[base+6];
            exp_tag = { mem[base+40], mem[base+39] };
        end
    endtask

    // ---- encrypt one vector through APB --------------------------------
    // prewrite=1: write the next block's DIN while the core is still busy
    // with the current one (checks DIN writes during busy are safe).
    reg enc_failed;

    task run_encrypt;
        input integer v;
        input         prewrite;
        begin
            load_vector(v);
            enc_failed = 1'b0;
            write128(ADDR_KEY0, key_v);
            write128(ADDR_NONCE0, nonce_v);
            apb_write(ADDR_CMD, build_cmd(OP_INIT, 1'b0, 1'b0, 5'd0));
            if (last_pslverr) enc_failed = 1'b1;
            wait_done;
            if (st[ST_TAG_FAIL]) enc_failed = 1'b1; // must start clean

            for (j = 0; j < n_ad; j = j + 1) begin
                write128(ADDR_DIN0, ad_blk(base, j));
                apb_write(ADDR_CMD, build_cmd(OP_PROC_AD, ad_last(base, j), 1'b0, ad_vb(base, j)));
                if (last_pslverr) enc_failed = 1'b1;
                wait_done;
            end

            if (prewrite) write128(ADDR_DIN0, pt_blk(base, 0));
            for (j = 0; j < n_pt; j = j + 1) begin
                vb  = pt_vb(base, j);
                lst = pt_last(base, j);
                if (!prewrite) write128(ADDR_DIN0, pt_blk(base, j));
                apb_write(ADDR_CMD, build_cmd(OP_PROC_TEXT, lst, 1'b0, vb));
                if (last_pslverr) enc_failed = 1'b1;
                if (prewrite && (j + 1 < n_pt)) begin
                    apb_read(ADDR_STATUS, rd);
                    if (!rd[ST_BUSY] && !rd[ST_DONE]) enc_failed = 1'b1;
                    write128(ADDR_DIN0, pt_blk(base, j + 1));
                end
                wait_done;
                if (!st[ST_DOUT_VALID]) enc_failed = 1'b1;
                read128(ADDR_DOUT0, got);
                exp_blk = lst ? (ct_blk(base, j) & byte_mask(vb)) : ct_blk(base, j);
                if (got !== exp_blk) enc_failed = 1'b1;   // full 128-bit compare
            end

            apb_write(ADDR_CMD, build_cmd(OP_FINAL, 1'b0, 1'b0, 5'd0));
            if (last_pslverr) enc_failed = 1'b1;
            wait_done;
            if (!st[ST_TAG_VALID] || st[ST_TAG_FAIL]) enc_failed = 1'b1;
            read128(ADDR_TAG0, got);
            if (got !== exp_tag) enc_failed = 1'b1;
        end
    endtask

    // ---- decrypt one vector through APB --------------------------------
    // flip_tag=1: corrupt bit 0 of TAGIN (negative test)
    reg dec_failed;

    task run_decrypt;
        input integer v;
        input         flip_tag;
        begin
            load_vector(v);
            dec_failed = 1'b0;
            write128(ADDR_KEY0, key_v);
            write128(ADDR_NONCE0, nonce_v);
            apb_write(ADDR_CMD, build_cmd(OP_INIT, 1'b0, 1'b1, 5'd0));
            if (last_pslverr) dec_failed = 1'b1;
            wait_done;

            for (j = 0; j < n_ad; j = j + 1) begin
                write128(ADDR_DIN0, ad_blk(base, j));
                apb_write(ADDR_CMD, build_cmd(OP_PROC_AD, ad_last(base, j), 1'b1, ad_vb(base, j)));
                if (last_pslverr) dec_failed = 1'b1;
                wait_done;
            end

            for (j = 0; j < n_pt; j = j + 1) begin
                vb  = pt_vb(base, j);
                lst = pt_last(base, j);
                write128(ADDR_DIN0, ct_blk(base, j));
                apb_write(ADDR_CMD, build_cmd(OP_PROC_TEXT, lst, 1'b1, vb));
                if (last_pslverr) dec_failed = 1'b1;
                wait_done;
                if (lst) begin
                    // last block must be held back until the tag is checked
                    if (st[ST_DOUT_VALID]) dec_failed = 1'b1;
                end else begin
                    if (!st[ST_DOUT_VALID]) dec_failed = 1'b1;
                    read128(ADDR_DOUT0, got);
                    if (got !== pt_blk(base, j)) dec_failed = 1'b1;
                end
            end

            write128(ADDR_TAGIN0, flip_tag ? (exp_tag ^ 128'h1) : exp_tag);
            apb_write(ADDR_CMD, build_cmd(OP_FINAL, 1'b0, 1'b1, 5'd0));
            if (last_pslverr) dec_failed = 1'b1;
            wait_done;

            // the computed tag is never published on decrypt
            if (st[ST_TAG_VALID]) dec_failed = 1'b1;
            read128(ADDR_TAG0, got);
            if (got !== 128'h0) dec_failed = 1'b1;

            j  = n_pt - 1;
            vb = pt_vb(base, j);
            if (flip_tag) begin
                if (!st[ST_TAG_FAIL] || st[ST_DOUT_VALID]) dec_failed = 1'b1;
                if (n_pt == 1) begin
                    // single-block message: no plaintext ever reached DOUT
                    read128(ADDR_DOUT0, got);
                    if (got !== 128'h0) dec_failed = 1'b1;
                end
            end else begin
                if (st[ST_TAG_FAIL] || !st[ST_DOUT_VALID]) dec_failed = 1'b1;
                read128(ADDR_DOUT0, got);
                if (got !== (pt_blk(base, j) & byte_mask(vb))) dec_failed = 1'b1;
            end
        end
    endtask

    // ---- helpers for the command-check tests -----------------------------
    integer chk_errors;
    reg [31:0] st_before;

    // issue a command that must be rejected; the core must not start and
    // the done bit must be unchanged
    task expect_reject;
        input [31:0] cmd_word;
        input [8*24-1:0] name;
        begin
            apb_read(ADDR_STATUS, st_before);
            apb_write(ADDR_CMD, cmd_word);
            apb_read(ADDR_STATUS, rd);
            if (last_pslverr !== 1'b1 || rd[ST_BUSY] || !rd[ST_CMD_ERR] ||
                rd[ST_DONE] !== st_before[ST_DONE]) begin
                chk_errors = chk_errors + 1;
                $display("FAIL cmd_checks: '%0s' not rejected cleanly (pslverr=%b STATUS=%h)",
                          name, last_pslverr, rd);
            end
        end
    endtask

    task expect_accept;
        input [31:0] cmd_word;
        input [8*24-1:0] name;
        begin
            apb_write(ADDR_CMD, cmd_word);
            if (last_pslverr !== 1'b0) begin
                chk_errors = chk_errors + 1;
                $display("FAIL cmd_checks: '%0s' rejected (pslverr=1)", name);
            end
            wait_done;
            if (st[ST_CMD_ERR]) begin
                chk_errors = chk_errors + 1;
                $display("FAIL cmd_checks: cmd_err not cleared by '%0s'", name);
            end
        end
    endtask

    task fill_din;
        begin
            write128(ADDR_DIN0, 128'h0f0e0d0c0b0a09080706050403020100);
        end
    endtask

    // ---- main ------------------------------------------------------------
    integer v, n_pass, n_run, total_fail;
    integer dec_pass, neg_pass, neg_run;
    reg     t_ok;

    initial begin
        $readmemh("tb/directed/kat_128_128.hex", mem);
        zero128 = 128'h0;

        pclk = 1'b0; presetn = 1'b0;
        psel = 1'b0; penable = 1'b0; pwrite = 1'b0; paddr = 8'h0; pwdata = 32'h0;
        total_fail = 0;
        chk_errors = 0;

        @(negedge pclk); @(negedge pclk);
        presetn = 1'b1;

        // 1. decrypt every KAT vector through APB
        dec_pass = 0;
        for (v = 0; v < N_VEC; v = v + 1) begin
            run_decrypt(v, 1'b0);
            if (!dec_failed) dec_pass = dec_pass + 1;
            else if (dec_pass == v) $display("FAIL decrypt_kat first failure at vector index %0d", v);
        end
        if (dec_pass == N_VEC) $display("PASSED decrypt_kat %0d/%0d", dec_pass, N_VEC);
        else begin $display("FAIL decrypt_kat %0d/%0d", dec_pass, N_VEC); total_fail = total_fail + 1; end

        // 2. negative decrypt: flipped tag on every 7th vector
        neg_pass = 0; neg_run = 0;
        for (v = 0; v < N_VEC; v = v + 7) begin
            run_decrypt(v, 1'b1);
            neg_run = neg_run + 1;
            if (!dec_failed) neg_pass = neg_pass + 1;
        end
        if (neg_pass == neg_run) $display("PASSED decrypt_neg %0d/%0d", neg_pass, neg_run);
        else begin $display("FAIL decrypt_neg %0d/%0d", neg_pass, neg_run); total_fail = total_fail + 1; end

        // 3. new session right after a failed decrypt starts clean
        run_decrypt(680, 1'b1);                 // AD 20 B, PT 20 B, tag flipped
        t_ok = !dec_failed;
        run_encrypt(680, 1'b0);                 // run_encrypt checks tag_fail=0 after INIT
        t_ok = t_ok && !enc_failed;
        if (t_ok) $display("PASSED tag_fail_clear 1/1");
        else begin $display("FAIL tag_fail_clear"); total_fail = total_fail + 1; end

        // 4. DIN written-word mask
        t_ok = 1'b1;
        write128(ADDR_KEY0, 128'h0);
        write128(ADDR_NONCE0, 128'h0);
        apb_write(ADDR_CMD, build_cmd(OP_INIT, 1'b0, 1'b0, 5'd0)); wait_done;
        apb_write(ADDR_DIN0, 32'h1); apb_write(ADDR_DIN0, 32'h2);
        apb_write(ADDR_DIN0, 32'h3); apb_write(ADDR_DIN0, 32'h4);
        apb_read(ADDR_STATUS, rd);
        if (rd[ST_DIN_FULL]) t_ok = 1'b0;          // same word 4x != full block
        apb_write(ADDR_CMD, build_cmd(OP_PROC_TEXT, 1'b1, 1'b0, 5'd3));
        if (last_pslverr !== 1'b1) t_ok = 1'b0;
        fill_din; fill_din;                        // 8 writes, all words covered
        apb_read(ADDR_STATUS, rd);
        if (!rd[ST_DIN_FULL]) t_ok = 1'b0;
        apb_write(ADDR_CMD, build_cmd(OP_PROC_TEXT, 1'b1, 1'b0, 5'd3));
        if (last_pslverr !== 1'b0) t_ok = 1'b0;
        wait_done;
        apb_read(ADDR_STATUS, rd);
        if (rd[ST_DIN_FULL]) t_ok = 1'b0;          // cleared by the accepted command
        apb_write(ADDR_CMD, build_cmd(OP_FINAL, 1'b0, 1'b0, 5'd0)); wait_done;
        if (t_ok) $display("PASSED din_mask 1/1");
        else begin $display("FAIL din_mask"); total_fail = total_fail + 1; end

        // 5. command checks
        expect_reject(build_cmd(OP_FINAL, 1'b0, 1'b0, 5'd0),        "FINAL without session");
        expect_reject(build_cmd(3'd5, 1'b0, 1'b0, 5'd0),            "reserved opcode 5");
        expect_reject(build_cmd(3'd6, 1'b0, 1'b0, 5'd0),            "reserved opcode 6");
        fill_din;
        expect_reject(build_cmd(OP_PROC_AD, 1'b1, 1'b0, 5'd0),      "PROC_AD without session");
        expect_accept(build_cmd(OP_INIT, 1'b0, 1'b1, 5'd0),         "INIT (decrypt)");
        expect_reject(build_cmd(OP_FINAL, 1'b0, 1'b1, 5'd0),        "FINAL right after INIT");
        fill_din;
        expect_reject(build_cmd(OP_PROC_TEXT, 1'b1, 1'b1, 5'd16),   "last=1 valid_bytes=16");
        expect_reject(build_cmd(OP_PROC_AD, 1'b1, 1'b1, 5'd20),     "last=1 valid_bytes=20");
        expect_reject(build_cmd(OP_PROC_AD, 1'b0, 1'b0, 5'd0),      "mode mismatch on AD");
        expect_accept(build_cmd(OP_PROC_AD, 1'b1, 1'b1, 5'd4),      "PROC_AD last");
        fill_din;
        expect_reject(build_cmd(OP_PROC_AD, 1'b1, 1'b1, 5'd4),      "PROC_AD after last AD");
        expect_accept(build_cmd(OP_PROC_TEXT, 1'b0, 1'b1, 5'd0),    "PROC_TEXT non-last");
        fill_din;
        expect_reject(build_cmd(OP_PROC_AD, 1'b1, 1'b1, 5'd4),      "PROC_AD after PROC_TEXT");
        expect_reject(build_cmd(OP_PROC_TEXT, 1'b1, 1'b0, 5'd4),    "encrypt-mode last block");
        expect_reject(build_cmd(OP_FINAL, 1'b0, 1'b1, 5'd0),        "FINAL before last block");
        expect_accept(build_cmd(OP_PROC_TEXT, 1'b1, 1'b1, 5'd4),    "PROC_TEXT last");
        fill_din;
        expect_reject(build_cmd(OP_PROC_TEXT, 1'b1, 1'b1, 5'd4),    "PROC_TEXT after last");
        expect_reject(build_cmd(OP_FINAL, 1'b0, 1'b0, 5'd0),        "FINAL mode mismatch");
        expect_accept(build_cmd(OP_FINAL, 1'b0, 1'b1, 5'd0),        "FINAL");
        apb_write(ADDR_CMD, build_cmd(OP_NOP, 1'b0, 1'b0, 5'd0));
        if (last_pslverr !== 1'b0) begin
            chk_errors = chk_errors + 1; $display("FAIL cmd_checks: NOP raised pslverr");
        end
        if (chk_errors == 0) $display("PASSED cmd_checks 19/19");
        else begin $display("FAIL cmd_checks %0d error(s)", chk_errors); total_fail = total_fail + 1; end

        // 6. KEY/NONCE/TAGIN writes while busy are ignored
        t_ok = 1'b1;
        load_vector(1088);                          // AD 32 B, PT 32 B
        write128(ADDR_KEY0, key_v);
        write128(ADDR_NONCE0, nonce_v);
        apb_write(ADDR_CMD, build_cmd(OP_INIT, 1'b0, 1'b0, 5'd0));
        apb_write(ADDR_NONCE0, 32'hDEADBEEF);       // p12 still running
        apb_write(ADDR_KEY0, 32'hDEADBEEF);
        wait_done;
        for (j = 0; j < n_ad; j = j + 1) begin
            write128(ADDR_DIN0, ad_blk(base, j));
            apb_write(ADDR_CMD, build_cmd(OP_PROC_AD, ad_last(base, j), 1'b0, ad_vb(base, j)));
            wait_done;
        end
        for (j = 0; j < n_pt; j = j + 1) begin
            write128(ADDR_DIN0, pt_blk(base, j));
            apb_write(ADDR_CMD, build_cmd(OP_PROC_TEXT, pt_last(base, j), 1'b0, pt_vb(base, j)));
            wait_done;
            read128(ADDR_DOUT0, got);
            if ((got & byte_mask(pt_vb(base, j))) !== (ct_blk(base, j) & byte_mask(pt_vb(base, j))))
                t_ok = 1'b0;
        end
        apb_write(ADDR_CMD, build_cmd(OP_FINAL, 1'b0, 1'b0, 5'd0));
        apb_write(ADDR_KEY0 + 8'h04, 32'hDEADBEEF); // finalization still running
        apb_write(ADDR_TAGIN0, 32'hDEADBEEF);
        wait_done;
        read128(ADDR_TAG0, got);
        if (got !== exp_tag) t_ok = 1'b0;
        if (t_ok) $display("PASSED busy_write_lock 1/1");
        else begin $display("FAIL busy_write_lock"); total_fail = total_fail + 1; end

        // 7. DOUT beyond valid_bytes reads 0 (encrypt; decrypt is covered by 1.)
        n_pass = 0; n_run = 0;
        for (v = 1*33; v < 16*33; v = v + 33) begin // PT 1..15 B, AD empty
            run_encrypt(v, 1'b0);                   // run_encrypt compares all 128 bits
            n_run = n_run + 1;
            if (!enc_failed) n_pass = n_pass + 1;
        end
        if (n_pass == n_run) $display("PASSED dout_mask %0d/%0d", n_pass, n_run);
        else begin $display("FAIL dout_mask %0d/%0d", n_pass, n_run); total_fail = total_fail + 1; end

        // 8. SOFT_RESET ends the session and clears DOUT/TAG
        t_ok = 1'b1;
        run_encrypt(700, 1'b0);                     // leaves a tag in TAG0..3
        load_vector(700);
        write128(ADDR_KEY0, key_v);
        write128(ADDR_NONCE0, nonce_v);
        apb_write(ADDR_CMD, build_cmd(OP_INIT, 1'b0, 1'b0, 5'd0)); wait_done;
        write128(ADDR_DIN0, pt_blk(base, 0));
        apb_write(ADDR_CMD, build_cmd(OP_PROC_TEXT, 1'b0, 1'b0, 5'd0)); wait_done;
        apb_write(ADDR_CMD, build_cmd(OP_SOFT_RESET, 1'b0, 1'b0, 5'd0));
        if (last_pslverr) t_ok = 1'b0;
        wait_done;
        read128(ADDR_DOUT0, got); if (got !== 128'h0) t_ok = 1'b0;
        read128(ADDR_TAG0, got);  if (got !== 128'h0) t_ok = 1'b0;
        if (st[ST_DIN_FULL] || st[ST_TAG_FAIL]) t_ok = 1'b0;
        apb_write(ADDR_CMD, build_cmd(OP_FINAL, 1'b0, 1'b0, 5'd0));
        if (last_pslverr !== 1'b1) t_ok = 1'b0;     // no session any more
        run_encrypt(700, 1'b0);
        if (enc_failed) t_ok = 1'b0;
        if (t_ok) $display("PASSED soft_reset 1/1");
        else begin $display("FAIL soft_reset"); total_fail = total_fail + 1; end

        // 9. next block's DIN written while the core is busy
        n_pass = 0; n_run = 0;
        for (v = 16*33; v < N_VEC; v = v + 37) begin // PT >= 16 B -> >= 2 blocks
            run_encrypt(v, 1'b1);
            n_run = n_run + 1;
            if (!enc_failed) n_pass = n_pass + 1;
        end
        if (n_pass == n_run) $display("PASSED din_prewrite %0d/%0d", n_pass, n_run);
        else begin $display("FAIL din_prewrite %0d/%0d", n_pass, n_run); total_fail = total_fail + 1; end

        u_apb_checker.report_summary;
        if (apb_checker_violations == 0)
            $display("PASSED apb_protocol_checker (0 violations)");
        else begin
            $display("FAIL apb_protocol_checker %0d violation(s)", apb_checker_violations);
            total_fail = total_fail + 1;
        end

        if (total_fail == 0) $display("PASSED ALL");
        else                 $display("FAILED (see FAIL lines above)");
        $finish;
    end

endmodule
