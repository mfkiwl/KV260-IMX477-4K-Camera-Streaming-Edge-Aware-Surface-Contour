"""Compile VHDL-2008, simulate the JPEG stream and check the resulting BMP."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess

from PIL import Image

from compare import compare

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_INPUT = ROOT / 'images/PIC1.JPG'
REFERENCE = ROOT / 'images/Designer1_PIC1_2048x1152.jpg'


def simulator(name):
    names = ('nvc', 'ghdl') if name == 'auto' else (name,)
    for candidate in names:
        executable = shutil.which(os.environ.get(candidate.upper(), candidate))
        if executable:
            return candidate, str(Path(executable).resolve())
    raise SystemExit('Install NVC or GHDL and put its executable on PATH, or set NVC or GHDL to its path.')


def run():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sim', choices=('auto','nvc','ghdl'), default='auto')
    parser.add_argument('--input', type=Path, default=DEFAULT_INPUT)
    parser.add_argument('--output', type=Path, help='default: results/<source stem>.bmp')
    parser.add_argument('--reference', type=Path, help='default for the supplied PIC1: Designer1 JPEG')
    parser.add_argument('--build', type=Path, help='directory for the simulator work library and logs')
    parser.add_argument('--no-stalls', action='store_true', help='continuous source and ready sink')
    parser.add_argument('--check-model', action='store_true', help='check every accepted 30-bit RGB payload against the raster model')
    parser.add_argument('--require-exact', action='store_true', help='return a failure status for any difference from the reference')
    args = parser.parse_args()
    name, exe = simulator(args.sim)
    source = args.input.resolve()
    output = (args.output or ROOT/'results'/f'{source.stem}.bmp').resolve()
    build = (args.build or ROOT/'build'/name).resolve()
    reference = args.reference.resolve() if args.reference else REFERENCE if source == DEFAULT_INPUT else None
    if args.require_exact and reference is None:
        parser.error('--require-exact needs --reference for this input')
    if output in (source,reference):
        parser.error('The capture must have its own output path')
    build.mkdir(parents=True, exist_ok=True)
    output.parent.mkdir(parents=True, exist_ok=True)
    with Image.open(source) as header:
        width,height = header.size
    sources = [str(ROOT/line) for line in (ROOT/'sim/sources.txt').read_text().splitlines() if line.strip()]
    settings = [f'-gG_INPUT={source}', f'-gG_OUTPUT={output}', f'-gG_WIDTH={width}',
                f'-gG_HEIGHT={height}', f'-gG_STALLS={str(not args.no_stalls).lower()}']
    decoded, trace = build/'decoded_stimulus.bmp', build/'accepted_rgb10.bin'
    if args.check_model:
        settings += [f'-gG_DECODED={decoded}', f'-gG_TRACE10={trace}']
    if name == 'ghdl':
        commands = [[exe,'-a','--std=08',*sources], [exe,'-e','--std=08','tb_pic1'],
                    [exe,'-r','--std=08','tb_pic1',*settings,'--assert-level=error']]
    else:
        commands = [[exe,'--std=2008','-a',*sources], [exe,'--std=2008','-e','-O3',*settings,'tb_pic1'],
                    [exe,'--std=2008','-H','512m','-r','tb_pic1']]
    for command in commands[:-1]:
        subprocess.run(command, cwd=build, check=True)
    with (build/'simulation.log').open('w',encoding='utf-8') as log:
        with subprocess.Popen(commands[-1],cwd=build,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,
                              text=True,errors='replace') as process:
            for line in process.stdout:
                print(line,end='',flush=True)
                log.write(line)
            if process.wait():
                raise SystemExit(f'{name} simulation failed. See {log.name}')
    if args.check_model:
        from check_model import check
        if not check(decoded,trace):
            raise SystemExit('RGB10 model check failed')
    if reference is not None:
        exact = compare(output,reference)
        if args.require_exact and not exact:
            return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(run())
