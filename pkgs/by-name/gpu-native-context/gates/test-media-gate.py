#!/usr/bin/env python3
"""CPU-only FFmpeg oracle regression: layout, exactness and bad-output rejection."""
import importlib.util
import copy
from pathlib import Path
import tempfile

spec = importlib.util.spec_from_file_location('gate', Path(__file__).with_name('media-gate.py'))
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)
reference = gate.fixture()
with tempfile.TemporaryDirectory(prefix='media-oracle-') as tmp:
    out = Path(tmp)
    ref = out / 'reference.yuv'
    ref.write_bytes(reference)
    nv12 = out / 'reference.nv12'
    gate.run(out, 'to-nv12', ['ffmpeg', '-nostdin', '-hide_banner', '-loglevel', 'error',
                            '-f', 'rawvideo', '-pixel_format', 'yuv420p', '-video_size', f'{gate.W}x{gate.H}',
                            '-i', ref, '-pix_fmt', 'nv12', '-f', 'rawvideo', nv12])
    assert gate.validate(out, 'nv12', ref, nv12, 'nv12', True) == float('inf')
    nv12_content = nv12.read_bytes()
    assert gate.nv12_to_planar(nv12_content) == reference
    for bad in (nv12_content[:-1], nv12_content + b'\0', b''):
        try:
            gate.nv12_to_planar(bad)
        except ValueError:
            pass
        else:
            raise AssertionError('Accepted wrong NV12 frame count/shape')
    invalid = [reference[:-1], bytes(len(reference)), reference[:gate.FRAME] * gate.N,
               reference[gate.FRAME:] + reference[:gate.FRAME]]
    for i, bad in enumerate(invalid):
        actual = out / f'bad-{i}.yuv'
        actual.write_bytes(bad)
        try:
            gate.validate(out, f'bad-{i}', ref, actual, 'yuv420p', False)
        except ValueError:
            pass
        else:
            raise AssertionError('Accepted truncated, blank, repeated or reordered video')
    near = bytearray(reference)
    near[0] += 1
    actual = out / 'near.yuv'
    actual.write_bytes(near)
    assert gate.validate(out, 'near-lossy', ref, actual, 'yuv420p', False) > 30
    try:
        gate.validate(out, 'near-exact', ref, actual, 'yuv420p', True)
    except ValueError:
        pass
    else:
        raise AssertionError('Accepted nonidentical pixels for exact decode')
    # 10-bit layout/exactness uses FFmpeg's independent conversion, including
    # low-bit loss that a permissive lossy PSNR threshold would miss.
    ten = gate.fixture10()
    ref10 = out / 'reference10.yuv'
    ref10.write_bytes(ten)
    p010 = out / 'reference.p010'
    gate.run(out, 'to-p010', ['ffmpeg', '-nostdin', '-hide_banner', '-loglevel', 'error',
                            '-f', 'rawvideo', '-pixel_format', 'yuv420p10le',
                            '-video_size', f'{gate.W}x{gate.H}', '-i', ref10, '-pix_fmt', 'p010le',
                            '-f', 'rawvideo', p010])
    assert gate.validate(out, 'p010', ref10, p010, 'p010le', True, 'yuv420p10le') == float('inf')
    samples = gate.struct.unpack(f'<{len(ten) // 2}H', ten)
    widened8 = gate.pack10([v & ~3 for v in samples])
    regenerated = gate.pack10([(v & ~3) | (i % 4) for i, v in enumerate(samples)])
    chroma8 = gate.pack10([v & ~3 if gate.W * gate.H <= i % gate.FRAME < gate.W * gate.H * 5 // 4
                          else v for i, v in enumerate(samples)])
    tied = list(samples)
    for y in range(gate.ROW_H):
        start = y * gate.W + 16
        tied[start:start + 16] = [samples[start] - 1] * 16
    gate.precision_oracle(ten, gate.pack10(tied))
    for name, bad in [('widened8', widened8), ('regenerated-residues', regenerated), ('chroma8', chroma8)]:
        actual = out / (name + '.yuv')
        actual.write_bytes(bad)
        # High PSNR does not prove retained source low-bit information.
        assert gate.validate(out, name + '-lossy', ref10, actual,
                             'yuv420p10le', False, 'yuv420p10le') > 30
        try:
            gate.precision_oracle(ten, bad)
        except ValueError:
            pass
        else:
            raise AssertionError(f'Accepted lost source low-bit information: {name}')
    for i, bad in enumerate([ten[:-2], bytes(len(ten)),
                             ten[:gate.FRAME * 2] * gate.N,
                             ten[gate.FRAME * 2:] + ten[:gate.FRAME * 2], widened8]):
        actual = out / f'bad10-{i}.yuv'
        actual.write_bytes(bad)
        try:
            gate.validate(out, f'bad10-{i}', ref10, actual, 'yuv420p10le', True, 'yuv420p10le')
        except ValueError:
            pass
        else:
            raise AssertionError('Accepted damaged, reordered or 8-bit-widened exact decode')

    ff = ['ffmpeg', '-nostdin', '-hide_banner', '-loglevel', 'error', '-xerror',
          '-y', '-threads', '1', '-filter_threads', '1']
    gate.prepare10(out, ff)
    metadata = gate.inspect_video(out, 'test-hdr-metadata', out / 'hdr10.hevc', hdr=True)
    # Compare rational values, not FFprobe's choice of denominator.
    equivalent = copy.deepcopy(metadata)
    mastering = next(side for frame in equivalent['frames'] for side in frame.get('side_data_list', [])
                     if side['side_data_type'] == 'Mastering display metadata')
    mastering['red_x'] = '177/250'
    gate.check_video(equivalent, hdr=True)
    for mutation in ('profile', 'depth', 'transfer', 'mastering', 'cll', 'missing-sei',
                     'late-only', 'middle-mastering-missing', 'middle-cll-missing'):
        bad = copy.deepcopy(metadata)
        if mutation == 'profile':
            bad['streams'][0]['profile'] = 'Main'
        elif mutation == 'depth':
            bad['frames'][0]['pix_fmt'] = 'yuv420p'
        elif mutation == 'transfer':
            bad['streams'][0]['color_transfer'] = 'bt709'
        elif mutation == 'late-only':
            for frame in bad['frames'][:-1]:
                frame['side_data_list'] = []
        elif mutation.startswith('middle-'):
            kind = ('Mastering display metadata' if mutation == 'middle-mastering-missing'
                    else 'Content light level metadata')
            frame = bad['frames'][gate.N // 2]
            frame['side_data_list'] = [side for side in frame.get('side_data_list', [])
                                       if side['side_data_type'] != kind]
        else:
            for frame in bad['frames']:
                if mutation == 'missing-sei':
                    frame['side_data_list'] = []
                for side in frame.get('side_data_list', []):
                    if mutation == 'mastering' and side['side_data_type'] == 'Mastering display metadata':
                        side['max_luminance'] = '100'
                    if mutation == 'cll' and side['side_data_type'] == 'Content light level metadata':
                        side['max_content'] = 100
        try:
            gate.check_video(bad, hdr=True)
        except ValueError:
            pass
        else:
            raise AssertionError(f'Accepted incorrect HDR metadata: {mutation}')

    # Independent real CPU application reference. Hable is NOT asserted to be
    # Intel's tone curve: the production oracle checks semantic invariants
    # and color-conversion discrimination, not agreement with that curve.
    linear = 'zscale=transfer=linear:npl=100,format=gbrpf32le,zscale=primaries=bt709'
    sdr = 'zscale=transfer=iec61966-2-1:matrix=bt709:range=limited,format=yuv420p'
    good = out / 'cpu-tonemap.yuv'
    gate.run(out, 'cpu-tonemap', ff + ['-c:v', 'hevc', '-i', out / 'hdr10.hevc', '-vf',
        linear + ',tonemap=tonemap=hable:desat=0:peak=10,' + sdr,
        '-pix_fmt', 'yuv420p', '-f', 'rawvideo', good])
    gate.tone_oracle(good.read_bytes())
    bad_filters = {
        'ignored': 'format=yuv420p',
        'clipped': linear + ',tonemap=tonemap=clip:desat=0:peak=10,' + sdr,
        'full-range': linear + ',tonemap=tonemap=hable:desat=0:peak=10,' +
                      sdr.replace('range=limited', 'range=full'),
        'wrong-matrix': 'setparams=colorspace=bt709,' + linear +
                        ',tonemap=tonemap=hable:desat=0:peak=10,' + sdr,
        'wrong-gamut': linear.replace('zscale=primaries=bt709', 'setparams=color_primaries=bt709') +
                       ',tonemap=tonemap=hable:desat=0:peak=10,' + sdr,
    }
    for name, filt in bad_filters.items():
        actual = out / (name + '.yuv')
        gate.run(out, name, ff + ['-c:v', 'hevc', '-i', out / 'hdr10.hevc', '-vf', filt,
                                 '-pix_fmt', 'yuv420p', '-f', 'rawvideo', actual])
        try:
            gate.tone_oracle(actual.read_bytes())
        except ValueError:
            pass
        else:
            raise AssertionError(f'Accepted broken tone mapping: {name}')
    content = good.read_bytes()
    # Adjacent 8-bit highlight levels still resolve different highlights.
    adjacent = bytearray(content)
    for t in range(gate.N):
        for row in (0, 3):
            for col in range(4, 8):
                x, y = ((col + t) % 8) * 16, row * gate.ROW_H
                for j in range(gate.ROW_H):
                    start = t * gate.FRAME + (y + j) * gate.W + x
                    adjacent[start:start + 16] = bytes([220 + col - 4]) * 16
    gate.tone_oracle(bytes(adjacent))
    swapped = b''.join(content[t * gate.FRAME:t * gate.FRAME + gate.W * gate.H] +
                       content[t * gate.FRAME + gate.W * gate.H * 5 // 4:(t + 1) * gate.FRAME] +
                       content[t * gate.FRAME + gate.W * gate.H:t * gate.FRAME + gate.W * gate.H * 5 // 4]
                       for t in range(gate.N))
    black_bottom = bytearray(content)
    start = (gate.N // 2) * gate.FRAME + 3 * gate.ROW_H * gate.W
    black_bottom[start:start + gate.ROW_H * gate.W] = b'\x10' * (gate.ROW_H * gate.W)
    invalid_tone = [content[:-1], bytes(len(content)), swapped,
                    content[:gate.FRAME] * gate.N,
                    content[gate.FRAME:] + content[:gate.FRAME], bytes(black_bottom)]
    for bad in invalid_tone:
        try:
            gate.tone_oracle(bad)
        except ValueError:
            pass
        else:
            raise AssertionError('Accepted corrupted tone-map output')
print('PASS: H264 and 10-bit PSNR/layout/exactness; semantic HDR metadata; CPU HDR-to-SDR reference and oracle-negative controls')
