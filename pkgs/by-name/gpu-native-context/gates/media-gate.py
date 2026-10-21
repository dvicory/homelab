#!/usr/bin/env python3
"""One bounded media gate per transport-owner invocation; never selects software fallback."""
import argparse
import hashlib
import json
import math
from fractions import Fraction
from pathlib import Path
import shlex
import subprocess
import struct

W, H, N = 128, 128, 16
FRAME = W * H * 3 // 2
ROW_H = H // 4


def fixture():
    frames = []
    for t in range(N):
        y = bytes(40 + ((x // 16 + y // 16 + t) % 6) * 28
                  for y in range(H) for x in range(W))
        u = bytes(80 + ((x // 8 + t) % 4) * 20
                  for y in range(H // 2) for x in range(W // 2))
        v = bytes(90 + ((y // 8 + t) % 4) * 20
                  for y in range(H // 2) for x in range(W // 2))
        frames.append(y + u + v)
    return b''.join(frames)


def validate(out, name, reference, actual, pixel_format, exact, reference_format='yuv420p'):
    size = FRAME * N * (2 if reference_format == 'yuv420p10le' else 1)
    if actual.stat().st_size != size or reference.stat().st_size != size:
        raise ValueError('Wrong frame count/shape')
    # FFmpeg owns pixel layout conversion and PSNR; only gate its machine stats.
    args = ['ffmpeg', '-nostdin', '-hide_banner', '-loglevel', 'error', '-xerror',
            '-threads', '1', '-filter_complex_threads', '1']
    for path, fmt in [(reference, reference_format), (actual, pixel_format)]:
        args += ['-f', 'rawvideo', '-pixel_format', fmt, '-video_size', f'{W}x{H}',
                 '-framerate', '16', '-i', path]
    # Pin the comparison depth: automatic negotiation must not discard the
    # low bits before an "exact" P010/planar-10 comparison.
    graph = (f'[0:v]format={reference_format}[ref];[1:v]format={reference_format}[actual];'
             '[ref][actual]psnr=stats_file=-:shortest=1:repeatlast=0')
    args += ['-filter_complex', graph, '-f', 'null', '-']
    run(out, name, args)
    rows = [line for line in (out / (name + '.log')).read_text().splitlines()
            if line.startswith('n:')]
    if len(rows) != N:
        raise ValueError(f'Wrong FFmpeg compared frame count: {len(rows)}')
    scores = [float(dict(field.split(':', 1) for field in row.split())['psnr_avg'])
              for row in rows]
    if any(math.isnan(score) or score < 30 or (exact and score != math.inf)
           for score in scores):
        raise ValueError(f'FFmpeg per-frame PSNR failed (exact={exact}): {scores}')
    return min(scores)


def run(out, name, args, trace=False):
    command = list(map(str, args))
    if trace:
        command = ['strace', '-f', '-yy', '-s', '256', '-e',
                   'trace=ioctl,mmap,munmap,poll,ppoll', '-o', str(out / (name + '.strace'))] + command
    with (out / (name + '.log')).open('x') as log:
        log.write('$ ' + shlex.join(command) + '\n')
        log.flush()
        # timeout kills the whole strace/FFmpeg process group, not just the wrapper.
        result = subprocess.run(['timeout', '--signal=TERM', '--kill-after=5s', '30s'] + command,
                                stdout=log, stderr=subprocess.STDOUT)
        log.write(f'\nexit={result.returncode}\n')
    if result.returncode:
        details = '\n'.join((out / (name + '.log')).read_text().splitlines()[-30:])
        raise RuntimeError(f'{name}: exit {result.returncode}; STOP, inspect '
                           f'{out / (name + ".log")} and trace\n{details}')


# BT.2100 PQ inverse EOTF, absolute RGB in cd/m², then BT.2020 NCL narrow range.
# https://www.itu.int/rec/R-REC-BT.2100
# https://github.com/FFmpeg/FFmpeg/blob/n9.0.1/libavutil/csp.c
GRAY_NITS = (0, 1, 10, 40, 100, 250, 500, 1000)
# Five-stop color contrast keeps matrix errors observable after 8-bit output
# quantization; fully saturated primaries can instead hide errors by clipping.
COLORS = ((1, .03125, .03125), (.03125, 1, .03125), (.03125, .03125, 1),
          (1, 1, .03125), (1, .03125, 1), (.03125, 1, 1), (.5, .5, .5), (0, 0, 0))
# Linear-light BT.709 -> BT.2020, D65; inverse is used only for fixture oracles.
TO2020 = ((.627404, .329283, .043313), (.069097, .919540, .011362),
          (.016391, .088013, .895595))
TO709 = ((1.660491, -.587641, -.072850), (-.124550, 1.132900, -.008349),
         (-.018151, -.100579, 1.118730))
MASTERING = dict(red_x='35400/50000', red_y='14600/50000',
                 green_x='8500/50000', green_y='39850/50000',
                 blue_x='6550/50000', blue_y='2300/50000',
                 white_point_x='15635/50000', white_point_y='16450/50000',
                 min_luminance='1/10000', max_luminance='1000')
HDR_TAGS = dict(color_range='tv', color_space='bt2020nc',
                color_transfer='smpte2084', color_primaries='bt2020')
SDR_TAGS = dict(color_range='tv', color_space='bt709',
                color_transfer='bt709', color_primaries='bt709')
HDR_GATES = [f'{api}-{mode}' for api in ('va', 'qsv')
             for mode in ('main10-decode', 'main10-encode', 'main10-transcode',
                          'hdr-decode', 'hdr-encode', 'hdr-transcode', 'tonemap')]


def matrix(m, v):
    return tuple(sum(a * b for a, b in zip(row, v)) for row in m)


def pq(nits):
    p = (max(nits, 0) / 10000) ** (2610 / 16384)
    return ((3424 / 4096 + 2413 / 128 * p) / (1 + 2392 / 128 * p)) ** (2523 / 32)


def unpq(value):
    p = max(value, 0) ** (32 / 2523)
    return 10000 * (max(p - 3424 / 4096, 0) / (2413 / 128 - 2392 / 128 * p)) ** (16384 / 2610)


def yuv(rgb, kr, kb, bits):
    r, g, b = rgb
    yy = kr * r + (1 - kr - kb) * g + kb * b
    scale = 1 << (bits - 8)
    return tuple(math.floor(scale * x + .5) for x in
                 (16 + 219 * yy, 128 + 224 * (b - yy) / (2 * (1 - kb)),
                  128 + 224 * (r - yy) / (2 * (1 - kr))))


def rgb(yuv_value, kr=.2126, kb=.0722):
    yy, u, v = yuv_value
    yy, u, v = (yy - 16) / 219, (u - 128) / 224, (v - 128) / 224
    r, b = yy + 2 * (1 - kr) * v, yy + 2 * (1 - kb) * u
    return r, (yy - kr * r - kb * b) / (1 - kr - kb), b


def pack10(samples):
    return struct.pack(f'<{len(samples)}H', *samples)


def fixture10():
    frames = []
    for t in range(N):
        planes = []
        for plane, step in ((0, 1), (1, 2), (2, 2)):
            for y in range(H // step):
                row = y * step // ROW_H
                for x in range(W // step):
                    col = (x * step // 16 - t) % 8
                    group = col // 4
                    # Four replicated flat patches share every upper bit.
                    # Their low-bit order changes spatially and temporally,
                    # so quantizing to 8-bit then inventing residues fails.
                    base = 64 + 4 * ((43 * plane + 31 * row + 61 * group + 7 * t) % 200)
                    planes.append(base + (col % 4 + t + row + plane) % 4)
        frames.append(pack10(planes))
    return b''.join(frames)


def chart_rgb(row, column):
    if row in (0, 3):
        return (GRAY_NITS[column],) * 3
    return tuple((10 if row == 1 else 40) * c for c in COLORS[column])


MAX_FALL = math.ceil(sum(sum(a * b for a, b in zip((.2126, .7152, .0722),
                                                 chart_rgb(row, col)))
                         for row in range(4) for col in range(8)) / 32)


def hdr_fixture():
    frames = []
    for t in range(N):
        patches = [[yuv(tuple(pq(c) for c in matrix(TO2020, chart_rgb(row, (col - t) % 8))),
                        .2627, .0593, 10) for col in range(8)] for row in range(4)]
        planes = []
        for plane, step in ((0, 1), (1, 2), (2, 2)):
            planes += [patches[y * step // ROW_H][x * step // 16][plane]
                       for y in range(H // step) for x in range(W // step)]
        frames.append(pack10(planes))
    return b''.join(frames)


def inspect_video(out, name, path, hdr=False, sdr=False):
    run(out, name, ['ffprobe', '-v', 'error', '-select_streams', 'v:0',
                    '-show_streams', '-show_frames', '-of', 'json', path])
    text = (out / (name + '.log')).read_text()
    data = json.loads(text.split('\n', 1)[1].rsplit('\nexit=', 1)[0])
    check_video(data, hdr, sdr)
    return data


def check_video(data, hdr=False, sdr=False):
    streams, frames = data['streams'], data['frames']
    if len(streams) != 1 or len(frames) != N:
        raise ValueError('Wrong video stream/frame count')
    stream = streams[0]
    profile = 'Main' if sdr else 'Main 10'
    if stream['codec_name'] != 'hevc' or stream['profile'] != profile:
        raise ValueError(f'Not HEVC {profile}')
    tags = HDR_TAGS if hdr else SDR_TAGS if sdr else {}
    for entry in [stream] + frames:
        fmt = 'yuv420p' if sdr else 'yuv420p10le'
        if (entry.get('width'), entry.get('height'), entry.get('pix_fmt')) != (W, H, fmt):
            raise ValueError('Wrong dimensions or decoded bit depth')
        if any(entry.get(key) != value for key, value in tags.items()):
            raise ValueError(f'Wrong color characteristics: {entry}')
    for frame in frames:
        # HEVC decoding persists SEI state; require that state on each
        # decoded frame, not a fresh SEI NAL unit on every coded frame.
        found = set()
        for side in frame.get('side_data_list', []):
            kind = side.get('side_data_type')
            if kind == 'Mastering display metadata':
                if sdr or any(Fraction(side.get(k, '-1')) != Fraction(v) for k, v in MASTERING.items()):
                    raise ValueError('Missing/wrong mastering display values, or stale HDR in SDR')
                found.add('mastering')
            if kind == 'Content light level metadata':
                if sdr or (side.get('max_content'), side.get('max_average')) != (1000, MAX_FALL):
                    raise ValueError('Wrong CLL/FALL values, or stale HDR in SDR')
                found.add('cll')
        if hdr and found != {'mastering', 'cll'}:
            raise ValueError('Missing semantic HDR10 static metadata on decoded frame')


def precision_oracle(reference, actual):
    """Require source-correlated low-bit distinctions, not exact lossy pixels."""
    if len(reference) != FRAME * N * 2 or len(actual) != len(reference):
        raise ValueError('Wrong precision frame count/shape')
    source = struct.unpack(f'<{len(reference) // 2}H', reference)
    decoded = struct.unpack(f'<{len(actual) // 2}H', actual)
    for t in range(N):
        response = [[0.] * 4 for _ in range(3)]
        for row in range(4):
            for group in range(2):
                before = [patch_means(source, t, row, 4 * group + col) for col in range(4)]
                after = [patch_means(decoded, t, row, 4 * group + col) for col in range(4)]
                for plane in range(3):
                    order = sorted(range(4), key=lambda col: before[col][plane])
                    if any(before[a][plane] >= before[b][plane] for a, b in zip(order, order[1:])):
                        raise ValueError('Precision source has lost distinct low-bit patch levels')
                    for rank, col in enumerate(order):
                        response[plane][rank] += after[col][plane]
        # Pool the eight groups: individual lossy ties are allowed, but each
        # frame and plane must retain all four input-correlated low-bit levels.
        for plane, levels in enumerate(response):
            if any(a >= b for a, b in zip(levels, levels[1:])):
                raise ValueError(f'Lost input-correlated 10-bit response: frame {t}, plane {plane}')


def prepare10(out, ff):
    for stem, content in [('known10', fixture10()), ('hdr10', hdr_fixture())]:
        raw_path, bitstream = out / (stem + '.yuv'), out / (stem + '.hevc')
        raw_path.write_bytes(content)
        # x265 lossless signals level 8.5, outside normal hardware profiles.
        # QP1 keeps a real Main10 stream; hardware decode compares exactly to
        # the independent CPU decode, not to the pre-encode raw source.
        params = 'qp=1:repeat-headers=1:pools=none:frame-threads=1:wpp=0:bframes=0:keyint=16'
        colors = []
        if stem == 'hdr10':
            params += (':hdr10=1:master-display=G(8500,39850)B(6550,2300)R(35400,14600)'
                       f'WP(15635,16450)L(10000000,1):max-cll=1000,{MAX_FALL}')
            # Declare the already-PQ/2020 input; output-only tags can convert
            # unlabelled YUV and lose primaries/transfer under FFmpeg negotiation.
            colors = ['-color_range', HDR_TAGS['color_range'],
                      '-colorspace', HDR_TAGS['color_space'],
                      '-color_trc', HDR_TAGS['color_transfer'],
                      '-color_primaries', HDR_TAGS['color_primaries']]
        run(out, stem + '-fixture-encode', ff + [
            '-f', 'rawvideo', '-pixel_format', 'yuv420p10le', '-video_size', f'{W}x{H}',
            '-framerate', '16'
        ] + colors + ['-i', raw_path, '-frames:v', str(N), '-c:v', 'libx265',
            '-preset', 'ultrafast', '-profile:v', 'main10', '-x265-params', params,
            '-f', 'hevc', bitstream])
        inspect_video(out, stem + '-fixture-metadata', bitstream, hdr=stem == 'hdr10')
        reference = out / (stem + '-reference.yuv')
        run(out, stem + '-fixture-reference', ff + ['-c:v', 'hevc', '-i', bitstream,
            '-pix_fmt', 'yuv420p10le', '-f', 'rawvideo', reference])
        validate(out, stem + '-fixture-psnr', raw_path, reference, 'yuv420p10le', False, 'yuv420p10le')
        if stem == 'known10':
            precision_oracle(content, reference.read_bytes())
    files = ['known10.yuv', 'known10.hevc', 'known10-reference.yuv',
             'hdr10.yuv', 'hdr10.hevc', 'hdr10-reference.yuv']
    (out / 'fixture10.sha256').write_text(''.join(
        hashlib.sha256((out / f).read_bytes()).hexdigest() + '  ' + f + '\n' for f in files))


def nv12_to_planar(content):
    """Reorder NV12 bytes only; never negotiate a color-space conversion."""
    if len(content) != FRAME * N:
        raise ValueError('Wrong NV12 frame count/shape')
    pixels = W * H
    frames = []
    for offset in range(0, len(content), FRAME):
        frame = content[offset:offset + FRAME]
        chroma = frame[pixels:]
        frames.append(frame[:pixels] + chroma[::2] + chroma[1::2])
    return b''.join(frames)


def patch_means(content, t, row, col):
    # The middle 8x8 luma / 4x4 chroma samples exclude subsampling/tile boundaries.
    x, y = ((col + t) % 8) * 16 + 4, row * ROW_H + (ROW_H - 8) // 2
    frame = content[t * FRAME:(t + 1) * FRAME]
    planes = (frame[:W * H], frame[W * H:W * H * 5 // 4], frame[W * H * 5 // 4:])
    return tuple(sum(plane[(y // step + j) * (W // step) + x // step + i]
                     for j in range(8 // step) for i in range(8 // step)) / (8 // step) ** 2
                 for plane, step in zip(planes, (1, 2, 2)))


def tone_oracle(content):
    """Curve-independent semantic oracle, not an invented Intel PSNR tolerance.

    VA/oneVPL specify HDR metadata and conversion, not a bit-exact tone curve.
    Require black/neutral narrow-range endpoints within one 8-bit quantization
    step, resolved highlights, non-PQ output, and correct color-conversion
    discrimination. No claim of perceptual/colorimetric conformance.
    """
    if len(content) != FRAME * N:
        raise ValueError('Wrong tone-map frame count/shape')
    for t in range(N):
        for row in (0, 3):
            neutral = [patch_means(content, t, row, c) for c in range(8)]
            if abs(neutral[0][0] - 16) > 1:
                raise ValueError('Tone-map black is not limited-range black')
            if any(not 15 <= yy <= 236 or abs(u - 128) > 1 or abs(v - 128) > 1
                   for yy, u, v in neutral):
                raise ValueError('Wrong SDR range or nonneutral gray')
            # Any strictly ordered distinct levels resolve the highlights;
            # color quantization corners do not justify a gray-spacing margin.
            if any(b[0] <= a[0] for a, b in zip(neutral, neutral[1:])):
                raise ValueError('Tone map lost shadow/highlight ordering or clipped')
            unchanged = [16 + 219 * pq(nits) for nits in GRAY_NITS]
            if sum(abs(p[0] - q) > 1 for p, q in zip(neutral, unchanged)) < 3:
                raise ValueError('PQ codes retained: ignored tone mapping')
        # Intel's H2S path applies a pseudo-Y tone scale and an sRGB OETF
        # before 709 CSC. Compare chromaticities, not an undocumented curve.
        # Quantization is propagated by evaluating the +/-1-code corners.
        for row in (1, 2):
            for col in range(6):
                observed = patch_means(content, t, row, col)
                desired = chart_rgb(row, col)
                pq2020 = tuple(pq(c) for c in matrix(TO2020, desired))
                yyuv = tuple(c / 4 for c in yuv(pq2020, .2627, .0593, 10))
                wrong_matrix = matrix(TO709, tuple(unpq(c) for c in rgb(yyuv)))
                wrong_gamut = matrix(TO2020, desired)
                candidates = [desired, wrong_matrix, wrong_gamut,
                              tuple(reversed(desired))]
                def chroma(v):
                    total = sum(max(c, 0) for c in v)
                    return tuple(max(c, 0) / total for c in v) if total else (0, 0, 0)
                expected = [chroma(v) for v in candidates]
                # Some colors are invariant under channel reversal. Exclude
                # only analytically identical negative hypotheses.
                negatives = [v for v in expected[1:] if v != expected[0]]
                winners = []
                for dy in (-1, 1):
                    for du in (-1, 1):
                        for dv in (-1, 1):
                            encoded = rgb(tuple(a + b for a, b in zip(observed, (dy, du, dv))))
                            linear = tuple(c / 12.92 if c <= .04045 else ((c + .055) / 1.055) ** 2.4
                                           for c in encoded)
                            actual = chroma(linear)
                            distance = lambda v: sum((a - b) ** 2 for a, b in zip(actual, v))
                            winners.append(all(distance(expected[0]) < distance(v) for v in negatives))
                if not any(winners):
                    raise ValueError(f'Wrong SDR colors at frame {t}, patch {row}/{col}: {observed}')
    return 'black/neutral/range, resolved highlights, non-PQ samples, independent 709 chromaticity discrimination'


def extended_gate(a, out, ff):
    run(out, a.gate + '-version', ['ffmpeg', '-version'])
    if a.gate == 'prepare-10bit':
        prepare10(out, ff)
        print('PASS 10-bit/PQ fixtures and independent CPU references only; no hardware acceptance')
        return
    if not a.transport_ready:
        raise ValueError('Hardware gate requires transport-owner --transport-ready; never run on host')
    for line in (out / 'fixture10.sha256').read_text().splitlines():
        digest, filename = line.split('  ', 1)
        if hashlib.sha256((out / filename).read_bytes()).hexdigest() != digest:
            raise ValueError('Prepared fixture/reference changed')
    is_hdr = '-hdr-' in a.gate or a.gate.endswith('tonemap')
    stem = 'hdr10' if is_hdr else 'known10'
    if (out / (stem + '.yuv')).read_bytes() != (hdr_fixture() if is_hdr else fixture10()):
        raise ValueError('Known 10-bit source changed')
    source, reference = out / (stem + '.hevc'), out / (stem + '-reference.yuv')
    inspect_video(out, a.gate + '-input-metadata', source, hdr=is_hdr)
    validate(out, a.gate + '-input-psnr', out / (stem + '.yuv'), reference,
             'yuv420p10le', False, 'yuv420p10le')
    qsv = a.gate.startswith('qsv-')
    backend, device = ('qsv', 'qs') if qsv else ('vaapi', 'va')
    # iHD's low-power HEVC path clamps QP below 10, independently of bit depth.
    # QSV CQP uses FF_QP2LAMBDA units; ICQ is a different quality mode.
    quality = (['-flags', '+qscale', '-global_quality', '1180'] if qsv else ['-qp', '10'])
    quality += ['-i_qfactor', '1', '-i_qoffset', '0']
    init = ['-init_hw_device', 'vaapi=va:' + a.device]
    if qsv:
        init += ['-init_hw_device', 'qsv=qs@va']
    decode = ['-hwaccel', backend, '-hwaccel_device', device,
              '-hwaccel_output_format', backend, '-c:v', 'hevc_qsv' if qsv else 'hevc', '-i', source]
    if a.gate.endswith('decode'):
        actual = out / (a.gate + '.p010')
        run(out, a.gate, ff + init + decode + ['-vf', 'hwdownload,format=p010le',
            '-pix_fmt', 'p010le', '-f', 'rawvideo', actual], trace=True)
        score = validate(out, a.gate + '-psnr', reference, actual, 'p010le', True, 'yuv420p10le')
        result = f'exact CPU-reference decode; PSNR={score}'
    elif a.gate.endswith('tonemap'):
        # There is no CPU tone-map fallback. Missing filter/caps is a failure.
        filt = ('vpp_qsv=tonemap=1:format=nv12:async_depth=1' if qsv else
                'tonemap_vaapi=format=nv12')
        downloaded = out / (a.gate + '.nv12')
        actual = out / (a.gate + '.yuv')
        bitstream = out / (a.gate + '.hevc')
        # Split after real hardware VPP. Preserve its native NV12 bytes: an
        # extra software format filter can also negotiate a matrix conversion.
        graph = (f'[0:v]{filt},split=2[pixels][encode];'
                 '[pixels]hwdownload,format=nv12[download]')
        args = init + decode + ['-filter_complex', graph, '-map', '[download]',
            '-c:v', 'rawvideo', '-pix_fmt', 'nv12', '-f', 'rawvideo', downloaded,
            '-map', '[encode]', '-c:v', 'hevc_qsv' if qsv else 'hevc_vaapi',
            '-profile:v', 'main', '-async_depth', '1', '-bf', '0']
        args += quality
        args += ['-f', 'hevc', bitstream]
        run(out, a.gate, ff + ['-filter_complex_threads', '1'] + args, trace=True)
        inspect_video(out, a.gate + '-output-metadata', bitstream, sdr=True)
        actual.write_bytes(nv12_to_planar(downloaded.read_bytes()))
        result = tone_oracle(actual.read_bytes())
        decoded = out / (a.gate + '-validation.yuv')
        run(out, a.gate + '-cpu-decode', ff + ['-c:v', 'hevc', '-i', bitstream,
            '-pix_fmt', 'yuv420p', '-f', 'rawvideo', decoded])
        tone_oracle(decoded.read_bytes())
        validate(out, a.gate + '-psnr', actual, decoded, 'yuv420p', False)
    else:
        args = init + ['-filter_hw_device', device]
        if a.gate.endswith('transcode'):
            args += decode
        elif is_hdr:
            # CPU decode here is intentional input preparation for the
            # separate hardware-encode gate, preserving actual frame SEI.
            args += ['-c:v', 'hevc', '-i', source, '-vf', 'format=p010le,hwupload=extra_hw_frames=8']
        else:
            args += ['-f', 'rawvideo', '-pixel_format', 'yuv420p10le',
                     '-video_size', f'{W}x{H}', '-framerate', '16', '-i', out / 'known10.yuv',
                     '-vf', 'format=p010le,hwupload=extra_hw_frames=8']
        bitstream, actual = out / (a.gate + '.hevc'), out / (a.gate + '-validation.yuv')
        args += ['-frames:v', str(N), '-c:v', 'hevc_qsv' if qsv else 'hevc_vaapi',
                 '-profile:v', 'main10', '-async_depth', '1', '-bf', '0']
        args += quality
        if is_hdr and not qsv:
            args += ['-sei', 'hdr']
        run(out, a.gate, ff + args + ['-f', 'hevc', bitstream], trace=True)
        inspect_video(out, a.gate + '-output-metadata', bitstream, hdr=is_hdr)
        run(out, a.gate + '-cpu-decode', ff + ['-c:v', 'hevc', '-i', bitstream,
            '-pix_fmt', 'yuv420p10le', '-f', 'rawvideo', actual])
        score = validate(out, a.gate + '-psnr', reference, actual, 'yuv420p10le', False, 'yuv420p10le')
        result = f'Main 10 profile/depth and independent CPU picture quality; minimum per-frame PSNR={score}'
        if is_hdr:
            result += '; per-frame PQ/2020/mastering/CLL state preserved; no exact lossy low-bit claim'
        else:
            precision_source = reference if a.gate.endswith('transcode') else out / 'known10.yuv'
            precision_oracle(precision_source.read_bytes(), actual.read_bytes())
            result += '; source-correlated ordered low-bit patch distinctions (not lossless encode)'
    (out / (a.gate + '.result')).write_text(f'PASS {a.gate}: {N} frames {W}x{H}; {result}\n')
    print((out / (a.gate + '.result')).read_text(), end='')


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('gate', choices=['prepare', 'va-decode', 'va-encode', 'qsv-session', 'qsv-decode', 'qsv-encode', 'qsv-transcode', 'prepare-10bit'] + HDR_GATES)
    p.add_argument('--out', type=Path, required=True, help='Private evidence directory, same directory for all gates')
    p.add_argument('--device', default='/dev/dri/renderD128')
    p.add_argument('--transport-ready', action='store_true', help='Owner has verified transport readback and host stop conditions')
    a = p.parse_args()
    out = a.out.resolve()
    out.mkdir(mode=0o700, parents=True, exist_ok=True)
    ff = ['ffmpeg', '-nostdin', '-hide_banner', '-loglevel', 'verbose', '-xerror', '-y', '-threads', '1', '-filter_threads', '1']
    raw = ['-f', 'rawvideo', '-pixel_format', 'yuv420p', '-video_size', f'{W}x{H}', '-framerate', '16', '-i', out / 'known.yuv']
    if a.gate == 'prepare-10bit' or a.gate in HDR_GATES:
        extended_gate(a, out, ff)
        return
    if a.gate == 'prepare':
        (out / 'known.yuv').write_bytes(fixture())
        run(out, 'fixture-encode', ff + raw + ['-frames:v', str(N), '-c:v', 'libx264', '-preset', 'ultrafast', '-profile:v', 'high', '-qp', '18', '-bf', '0', '-f', 'h264', out / 'known.h264'])
        run(out, 'fixture-reference', ff + ['-c:v', 'h264', '-i', out / 'known.h264', '-pix_fmt', 'yuv420p', '-f', 'rawvideo', out / 'reference.yuv'])
        validate(out, 'fixture-psnr', out / 'known.yuv', out / 'reference.yuv', 'yuv420p', False)
        (out / 'fixture.sha256').write_text(''.join(hashlib.sha256((out / f).read_bytes()).hexdigest() + '  ' + f + '\n' for f in ['known.yuv', 'known.h264', 'reference.yuv']))
        print('PASS fixture only (CPU generation/reference; no hardware acceptance)')
        return
    if not a.transport_ready:
        p.error('Hardware gate requires transport-owner --transport-ready; never run on host')
    if (out / 'known.yuv').read_bytes() != fixture():
        raise ValueError('Known input changed')
    validate(out, a.gate + '-reference-psnr', out / 'known.yuv', out / 'reference.yuv', 'yuv420p', False)
    va = ['-init_hw_device', 'vaapi=va:' + a.device]
    qsv = va + ['-init_hw_device', 'qsv=qs@va']
    if a.gate == 'qsv-session':
        run(out, a.gate, ['onevpl-session', a.device], trace=True)
        print('PASS oneVPL hardware VA display session only; codecs not yet accepted')
        return
    is_qsv = a.gate.startswith('qsv')
    backend = 'qsv' if is_qsv else 'vaapi'
    device = 'qs' if is_qsv else 'va'
    init = qsv if is_qsv else va
    if a.gate.endswith('decode'):
        decoder = ['-c:v', 'h264_qsv'] if is_qsv else ['-c:v', 'h264']
        args = init + ['-hwaccel', backend, '-hwaccel_device', device, '-hwaccel_output_format', backend] + decoder + ['-i', out / 'known.h264', '-vf', 'hwdownload,format=nv12', '-pix_fmt', 'nv12', '-f', 'rawvideo', out / (a.gate + '.nv12')]
        run(out, a.gate, ff + args, trace=True)
        score = validate(out, a.gate + '-psnr', out / 'reference.yuv', out / (a.gate + '.nv12'), 'nv12', True)
    else:
        bitstream = out / (a.gate + '.h264')
        if a.gate == 'qsv-transcode':
            args = init + ['-hwaccel', 'qsv', '-hwaccel_device', 'qs', '-hwaccel_output_format', 'qsv', '-c:v', 'h264_qsv', '-i', out / 'known.h264']
        else:
            args = init + ['-filter_hw_device', device] + raw + ['-vf', 'format=nv12,hwupload=extra_hw_frames=8']
        args += ['-frames:v', str(N), '-c:v', 'h264_qsv' if is_qsv else 'h264_vaapi', '-async_depth', '1']
        args += ['-global_quality', '18'] if is_qsv else ['-qp', '18']
        args += ['-bf', '0', '-f', 'h264', bitstream]
        run(out, a.gate, ff + args, trace=True)
        decoded = out / (a.gate + '-validation.yuv')
        run(out, a.gate + '-validate', ff + ['-c:v', 'h264', '-i', bitstream, '-pix_fmt', 'yuv420p', '-f', 'rawvideo', decoded])
        score = validate(out, a.gate + '-psnr', out / 'reference.yuv', decoded, 'yuv420p', False)
    (out / (a.gate + '.result')).write_text(f'PASS {a.gate}: {N} frames {W}x{H}; minimum per-frame PSNR={score}; decode exact={a.gate.endswith("decode")}\n')
    print((out / (a.gate + '.result')).read_text(), end='')


if __name__ == '__main__':
    main()
