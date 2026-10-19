"""Exercise actual scan controllability, capture ordering and indexed readout."""
from pathlib import Path
import subprocess
import tempfile
import unittest
from regional_scan_wrapper import ports,make_wrapper


class WrapperTests(unittest.TestCase):
    """Check boundaries with a separate arithmetic/packing expectation."""
    def test_alternate_reset_is_real_reset(self):
        fpga=Path(__file__).resolve().parents[1]
        runtime=fpga/'build/ov5640_pwm_20261012/tools/iverilog/app/bin'
        toy='''module toy(input clk,reset_n,input [2:0] a,output reg [2:0] y);
          always @(posedge clk or negedge reset_n)if(!reset_n)y<=0;else y<=a;
          endmodule'''
        wrapper,meta=make_wrapper(ports(toy,'toy',{}),'toy')
        self.assertEqual(meta['input_bits'],3)
        self.assertIn('.reset_n(rst_n)',wrapper)
        tb='''module tb;
          reg clk=0;always #5 clk=~clk;
          reg rst_n=0;reg [31:0] scan_in=0;reg scan_addr=0;
          wire [31:0] scan_out;regional_wrapper dut(.*);
          initial begin
           repeat(4)@(negedge clk);scan_in=5;rst_n=1;
           repeat(4)@(posedge clk);#1;
           if(scan_out!==5)$fatal(1,"alternate reset data");
           @(negedge clk);rst_n=0;@(posedge clk);#1;
           if(scan_out!==0)$fatal(1,"alternate reset assertion");
           $display("ALTERNATE_RESET_PASS");$finish;
          end
         endmodule'''
        with tempfile.TemporaryDirectory(dir=fpga/'build/route_optimization') as directory:
            build=Path(directory);source=build/'fixture.sv';source.write_text(toy+'\n'+wrapper+'\n'+tb)
            compiled=subprocess.run([str(runtime/'iverilog.exe'),'-g2012','-s','tb',
                '-o',str(build/'test.vvp'),str(source)],capture_output=True,text=True,timeout=30)
            self.assertEqual(compiled.returncode,0,compiled.stderr)
            simulated=subprocess.run([str(runtime/'vvp.exe'),str(build/'test.vvp')],
                capture_output=True,text=True,timeout=30)
            self.assertEqual(simulated.returncode,0,simulated.stdout+simulated.stderr)
            self.assertIn('ALTERNATE_RESET_PASS',simulated.stdout)

    def test_ambiguous_reset_rejected(self):
        with self.assertRaises(ValueError):
            ports('module toy(input clk,rst_n,reset_n,input a,output y);endmodule','toy',{})

    def test_shift_capture_and_all_words(self):
        fpga=Path(__file__).resolve().parents[1]
        runtime=fpga/'build/ov5640_pwm_20261012/tools/iverilog/app/bin'
        toy='''module toy(input clk,rst_n,input [47:0] a,input [16:0] b,
            output [64:0] y,output flag);
            assign y={a,b};assign flag=^a ^ ^b;endmodule'''
        wrapper,meta=make_wrapper(ports(toy,'toy',{}),'toy')
        self.assertEqual(meta['input_bits'],65)
        self.assertEqual(meta['output_bits'],66)
        tb='''module tb;
          reg clk=0;always #5 clk=~clk;
          reg rst_n=0;reg [31:0] scan_in=0;reg [1:0] scan_addr=0;
          wire [31:0] scan_out;
          regional_wrapper dut(.*);
          reg [95:0] expected_inputs=0,expected_capture=0;
          reg [95:0] previous_inputs=0;integer i,j;
          initial begin
            // Fill the unreset diagnostic bank before assessing its outputs.
            repeat(4) @(negedge clk);rst_n=1;
            for(i=1;i<=20;i=i+1)begin
              scan_in=32'h9e3779b9*i;
              previous_inputs=expected_inputs;
              expected_inputs={expected_inputs[63:0],scan_in};
              expected_capture=0;
              expected_capture[64:0]={previous_inputs[47:0],previous_inputs[64:48]};
              expected_capture[65]=^previous_inputs[47:0] ^ ^previous_inputs[64:48];
              @(posedge clk);#1;
              if(dut.scan_inputs!==expected_inputs) $fatal(1,"input scan order");
              if(i>3)begin
                for(j=0;j<4;j=j+1)begin
                  scan_addr=j;#0.1;
                  if(scan_out!==(j<3 ? expected_capture[j*32+:32] : 32'd0))
                    $fatal(1,"capture/index word %0d",j);
                end
              end
              @(negedge clk);
            end
            $display("SCAN_WRAPPER_PASS");$finish;
          end
        endmodule'''
        with tempfile.TemporaryDirectory(dir=fpga/'build/route_optimization') as directory:
            build=Path(directory);source=build/'fixture.sv';source.write_text(toy+'\n'+wrapper+'\n'+tb)
            compiled=subprocess.run([str(runtime/'iverilog.exe'),'-g2012','-s','tb',
                '-o',str(build/'test.vvp'),str(source)],capture_output=True,text=True,timeout=30)
            self.assertEqual(compiled.returncode,0,compiled.stderr)
            simulated=subprocess.run([str(runtime/'vvp.exe'),str(build/'test.vvp')],
                capture_output=True,text=True,timeout=30)
            self.assertEqual(simulated.returncode,0,simulated.stdout+simulated.stderr)
            self.assertIn('SCAN_WRAPPER_PASS',simulated.stdout)


if __name__=='__main__': unittest.main()
