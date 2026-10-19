"""Keep wide diagnostic DUT ports dynamic behind a small, legal IO boundary.

This is a physical-test fixture only. Every input bit is controllable through
a shift bank; every output bit is independently observable through an indexed
capture bank. Both A/B sides receive byte-identical wrappers. No production
module or protocol is modified, and no functional equivalence is inferred from
this serial fixture: that proof must already exist for the DUT implementations.
"""
import ast
import re


def integer_expression(text, parameters):
    """Evaluate only constant width arithmetic from the reviewed ANSI ports."""
    def walk(node):
        if isinstance(node,ast.Constant) and type(node.value) is int:
            return node.value
        if isinstance(node,ast.Name) and node.id in parameters:
            return parameters[node.id]
        if isinstance(node,ast.BinOp):
            a,b=walk(node.left),walk(node.right)
            if isinstance(node.op,ast.Add): return a+b
            if isinstance(node.op,ast.Sub): return a-b
            if isinstance(node.op,ast.Mult): return a*b
        raise ValueError('Unsupported diagnostic port expression: '+text)
    return walk(ast.parse(text,mode='eval').body)


def ports(text,top,parameters):
    """Read simple ANSI scalar/vector declarations without guessing widths."""
    text=re.sub(r'/\*.*?\*/|//[^\n]*','',text,flags=re.S)
    match=re.search(r'module\s+'+re.escape(top)+r'\b.*?\)\s*\((.*?)\);',text,re.S)
    if not match:
        # Support a nonparameterized toy DUT for fixture verification.
        match=re.search(r'module\s+'+re.escape(top)+r'\s*\((.*?)\);',text,re.S)
    if not match: raise ValueError('Unsupported module header')
    result=[];direction=None;width=1
    for item in match[1].split(','):
        item=item.strip()
        declaration=re.fullmatch(r'(input|output)\s+(?:(?:reg|wire|logic)\s+)*(\[[^]]+\])?\s*(\w+)',item)
        if declaration:
            direction,vector,name=declaration.groups();width=1
            if vector:
                msb,lsb=vector[1:-1].split(':')
                upper,lower=integer_expression(msb,parameters),integer_expression(lsb,parameters)
                if lower!=0 or upper<0: raise ValueError('Unsupported vector direction')
                width=upper+1
        elif re.fullmatch(r'\w+',item) and direction:
            name=item
        else: raise ValueError('Unsupported ANSI port: '+item)
        result.append((direction,name,width))
    if len({name for _,name,_ in result})!=len(result): raise ValueError('Duplicate port')
    if not all(('input',name,1) in result for name in ('clk','rst_n')):
        raise ValueError('Expected single-bit clock and reset')
    return result


def make_wrapper(port_list,top):
    """Generate registered boundaries with an independently indexed read mux.

    Shift/capture registers intentionally have no CE or reset, preventing a new
    wide fixture enable tree. They are initialized by shifting before use in
    simulation; the DUT itself retains its real reset pin and all reset logic.
    Indexed reads, rather than XOR compression, prevent output cancellation.
    """
    inputs=[p for p in port_list if p[0]=='input' and p[1] not in ('clk','rst_n')]
    outputs=[p for p in port_list if p[0]=='output']
    ni=sum(p[2] for p in inputs);no=sum(p[2] for p in outputs)
    if not ni or not no: raise ValueError('Dynamic input and output bits required')
    pi=((ni+31)//32)*32;po=((no+31)//32)*32;words=po//32;ab=max(1,(words-1).bit_length())
    code=['// Isolated diagnostic boundary; never instantiate in production.',
          'module regional_wrapper(input clk,rst_n,input [31:0] scan_in,',
          f' input [{ab-1}:0] scan_addr,output [31:0] scan_out);',
          f' reg [{pi-1}:0] scan_inputs /* synthesis syn_preserve=1 */;',
          f' wire [{no-1}:0] dut_outputs;',
          f' reg [{po-1}:0] scan_outputs /* synthesis syn_preserve=1 */;']
    shift="scan_in" if pi==32 else f'{{scan_inputs[{pi-33}:0],scan_in}}'
    code += [f' always @(posedge clk) scan_inputs <= {shift};',
             f" always @(posedge clk) scan_outputs <= {{{{{po-no}{{1'b0}}}},dut_outputs}};",
             f" assign scan_out=scan_addr<{words} ? scan_outputs[scan_addr*32+:32] : 32'd0;"]
    mapping=dict(clk='clk',rst_n='rst_n');offset=0
    for _,name,width in inputs:
        mapping[name]=f'scan_inputs[{offset}+:{width}]';offset+=width
    offset=0
    for _,name,width in outputs:
        mapping[name]=f'dut_outputs[{offset}+:{width}]';offset+=width
    code += [f' {top} dut('+',\n  '.join('.'+name+'('+mapping[name]+')' for _,name,_ in port_list)+');',
             'endmodule','']
    return '\n'.join(code),dict(input_bits=ni,input_padded_bits=pi,output_bits=no,
                                output_padded_bits=po,read_address_bits=ab,
                                package_ports=2+32+ab+32)
