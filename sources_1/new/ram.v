`timescale 1ns / 1ps


module ram (
    input       clk,
    input [9:0] address,
    input [7:0] wdata,
    input       wr_en,

    output [7:0] rdata
);

    reg [7:0] mem[0:2**10-1];  // 8bit짜리 메모리 공간 n개

    integer i;

    initial begin       // 메모리 값 초기화
        for (i = 0; i < 2 ** 10 - 1; i = i + 1) begin
            mem[i] = 0;
        end
    end

    always @(posedge clk) begin
        if (!wr_en) begin
            mem[address] <= wdata;
        end
    end

    assign rdata = mem[address];

endmodule
