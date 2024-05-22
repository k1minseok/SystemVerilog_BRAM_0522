`timescale 1ns / 1ps

interface ram_interface;
    logic       clk;
    logic       wr_en;
    logic [9:0] addr;
    logic [7:0] wdata;

    logic [7:0] rdata;
endinterface


class transaction;
    rand bit       wr_en;   // bit : 2state type
    rand bit [9:0] addr;
    rand bit [7:0] wdata;
    bit      [7:0] rdata;

    task display(string name);
        $display("[%s] wr_en: %x, addr: %x, wdata: %x, rdata: %x", name, wr_en,
                 addr, wdata, rdata);
    endtask

    // 제약사항 설정 -> 랜덤 값 범위 설정 가능 : 이름은 상관 없음
    // constraint c_addr {addr < 10;}
    constraint c_addr {addr inside {[10:19]};}    // addr = 10 ~ 19 범위
    constraint c_wdata1 {wdata < 100;}
    constraint c_wdata2 {wdata > 10;}
    // constraint c_wr_en {wr_en dist {0:=100, 1:=110};}   // 0~100까지 0, 101~110까지 1
    constraint c_wr_en {wr_en dist {0:/80, 1:/20};} // wr_en 0,1비율 60%, 40%
endclass


class generator;
    transaction            trans;
    mailbox #(transaction) gen2drv_mbox;
    event                  gen_next_event;

    function new(mailbox#(transaction) gen2drv_mbox, event gen_next_event);
        this.gen2drv_mbox   = gen2drv_mbox;
        this.gen_next_event = gen_next_event;

    endfunction

    task run(int count);
        repeat(count) begin // count만큼 계속 반복되면 transaction이 메모리에 
                            // count 숫자만큼 할당될 거 같지만 garbage collection이 동작해서
                            // 메모리에 있는 transaction class instance data가 자동으로
                            // 정리된다
            trans = new();
            assert (trans.randomize())
            else $error("[GEN] trans.radomize() error!");
            gen2drv_mbox.put(trans);
            trans.display("GEN");
            @(gen_next_event);  //
        end
    endtask
endclass


class driver;
    transaction trans;
    mailbox #(transaction) gen2drv_mbox;

    virtual ram_interface ram_intf;

    function new(virtual ram_interface ram_intf,
                 mailbox#(transaction) gen2drv_mbox);
        this.ram_intf = ram_intf;
        this.gen2drv_mbox = gen2drv_mbox;

    endfunction

    task reset ();      // task reset -> driver에는 보통 초기화 해주는 코드가 들어감
        ram_intf.wr_en <= 0;
        ram_intf.addr  <= 0;
        ram_intf.wdata <= 0;
        repeat (5) @(posedge ram_intf.clk);
    endtask

    task run();
        forever begin
            gen2drv_mbox.get(trans);
            ram_intf.wr_en <= trans.wr_en;
            ram_intf.addr  <= trans.addr;
            ram_intf.wdata <= trans.wdata;
            // if (trans.wr_en) begin  // read
            //     ram_intf.wr_en <= trans.wr_en;
            //     ram_intf.addr  <= trans.addr;
            // end else begin  // write
            //     ram_intf.wr_en <= trans.wr_en;
            //     ram_intf.addr  <= trans.addr;
            //     ram_intf.wdata <= trans.wdata;
            // end
            trans.display("DRV");
            @(posedge ram_intf.clk);
        end
    endtask
endclass


class monitor;
    transaction trans;
    mailbox #(transaction) mon2scb_mbox;

    virtual ram_interface ram_intf;

    function new(virtual ram_interface ram_intf,
                 mailbox#(transaction) mon2scb_mbox);
        this.ram_intf = ram_intf;
        this.mon2scb_mbox = mon2scb_mbox;
    endfunction

    task run();
        forever begin
            trans = new();
            @(posedge ram_intf.clk);
            trans.wr_en = ram_intf.wr_en;
            trans.addr  = ram_intf.addr;
            trans.wdata = ram_intf.wdata;
            trans.rdata = ram_intf.rdata;

            mon2scb_mbox.put(trans);
            trans.display("MON");
        end
    endtask
endclass


class scoreboard;
    transaction trans;
    mailbox #(transaction) mon2scb_mbox;
    event gen_next_event;

    int total_cnt, pass_cnt, fail_cnt, write_cnt;
    logic [7:0] mem[0:2**10-1];  // test용 메모리

    function new(mailbox#(transaction) mon2scb_mbox, event gen_next_event);
        this.mon2scb_mbox = mon2scb_mbox;
        this.gen_next_event = gen_next_event;
        total_cnt = 0;
        pass_cnt = 0;
        fail_cnt = 0;
        write_cnt = 0;

        for (int i = 0; i < 2 ** 10 - 1; i++) begin
            mem[i] = 0;
        end
    endfunction

    task run();
        forever begin
            mon2scb_mbox.get(trans);
            trans.display("SCB");
            if (trans.wr_en) begin  //read
                if (mem[trans.addr] == trans.rdata) begin
                    $display(" --> READ PASS! mem[%x] == %x", mem[trans.addr],
                             trans.rdata);
                    pass_cnt++;
                end else begin
                    $display(" --> READ FAIL! mem[%x] == %x", mem[trans.addr],
                             trans.rdata);
                    fail_cnt++;
                end
                // 초기 logic mem값에는 데이터가 저장되어 있지 않음(초기화했기때문에 값 모두 0)
                // dut의 reg mem도 같음 -> write하기 전까지 0 == 0 으로 비교되고
                // write한 후 제대로 저장 값과 출력 값이 보임
            end else begin  //write
                mem[trans.addr] = trans.wdata;
                $display(" --> WRITE! mem[%x] == %x", trans.addr, trans.wdata);
                write_cnt++;
            end

            total_cnt++;
            ->gen_next_event;
        end
    endtask
endclass


class environment;
    generator              gen;
    driver                 drv;
    monitor                mon;
    scoreboard             scb;

    event                  gen_next_event;

    mailbox #(transaction) gen2drv_mbox;
    mailbox #(transaction) mon2scb_mbox;


    function new(virtual ram_interface ram_intf);
        gen2drv_mbox = new();
        mon2scb_mbox = new();

        gen = new(gen2drv_mbox, gen_next_event);
        drv = new(ram_intf, gen2drv_mbox);
        mon = new(ram_intf, mon2scb_mbox);
        scb = new(mon2scb_mbox, gen_next_event);
    endfunction

    task pre_run();
        drv.reset();
    endtask

    task report();
        $display("================================");
        $display("       Final Report       ");
        $display("================================");
        $display("Total Test      : %d", scb.total_cnt);
        $display("READ Pass Count : %d", scb.pass_cnt);
        $display("READ Fail Count : %d", scb.fail_cnt);
        $display("WRITE Count     : %d", scb.write_cnt);
        $display("================================");
        $display("  test bench is finished! ");
        $display("================================");
    endtask


    task run();

        fork
            gen.run(10000);
            drv.run();
            mon.run();
            scb.run();
        join_any

        report();
        #10 $finish;
    endtask

    task run_test();
        pre_run();
        run();
    endtask
endclass


// test bench
// 초기화, 동작 코드
module tb_ram ();
    environment env;
    ram_interface ram_intf ();

    ram dut (
        .clk(ram_intf.clk),
        .address(ram_intf.addr),
        .wdata(ram_intf.wdata),
        .wr_en(ram_intf.wr_en),  // write enable

        .rdata(ram_intf.rdata)
    );

    always #5 ram_intf.clk = ~ram_intf.clk;

    initial begin
        ram_intf.clk = 0;
    end

    initial begin
        env = new(ram_intf);
        env.run_test();
    end

endmodule
