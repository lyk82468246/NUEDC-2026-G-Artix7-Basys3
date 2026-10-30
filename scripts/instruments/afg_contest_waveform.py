"""Offline A/B/C waveform builder; explicit voltage units and coherent periods."""
from fractions import Fraction
from functools import reduce
import math

from afg1022 import number, sample_codes, validate_settings


def build(settings):
    mode = settings['mode']
    if mode not in ('A', 'B', 'C'):
        raise ValueError('模式必须为 A / B / C')
    f0 = number(settings['f0_khz']) * 1000
    limit = 200e3 if mode == 'A' else 500e3
    rows = settings['tones']
    if len(rows) not in (2, 3):
        raise ValueError('题目要求基波加 1 或 2 个谐波')
    tones = []
    for row in rows:
        order = number(row['order'])
        peak = number(row['peak_mv']) / 1000
        phase = number(row['phase_deg'])
        if not order.is_integer() or order < 1 or peak <= 0:
            raise ValueError('阶次须为正整数，分量峰值须大于零')
        hz = f0 * order
        if not 10e3 <= hz <= limit:
            raise ValueError(f'{mode} 模式所有被测分量须在 10～{limit/1000:g} kHz')
        tones.append(dict(hz=hz, peak_v=peak, phase_deg=phase, order=int(order)))
    orders = [t['order'] for t in tones]
    if orders[0] != 1 or len(set(orders)) != len(orders):
        raise ValueError('第一行为基波（阶次 1），阶次不得重复')
    interference = None
    if mode == 'C':
        hz = number(settings['interference_khz']) * 1000
        vpp = number(settings['interference_vpp_mv']) / 1000
        if not 1e6 <= hz <= 10e6 or not 0 < vpp <= 1:
            raise ValueError('本工具支持干扰 1～10 MHz、0～1000 mVpp（不含零）')
        interference = dict(hz=hz, peak_v=vpp/2,
                            phase_deg=number(settings['interference_phase_deg']))
    all_tones = tones + ([interference] if interference else [])
    # Exact common period, to 1 micro-Hz; never approximate a discontinuous table.
    micro = []
    for tone in all_tones:
        value = Fraction(str(tone['hz'])) * 1_000_000
        rounded = round(value)
        if abs(float(value - rounded)) > 0.01:
            raise ValueError('频率精度超过 1 µHz')
        micro.append(rounded)
    common = reduce(math.gcd, micro) / 1e6
    points = int(settings['points'])
    if points not in (256, 512, 1000, 1024, 2048, 4096, 8192):
        raise ValueError('不支持的采样点数')
    highest = max(t['hz'] for t in all_tones)
    # Prefer 16 samples/highest-frequency cycle, with at least 8 required.
    max_cycles = math.floor(points * common / (8 * highest))
    min_cycles = max(1, math.ceil(points * common / 125e6), math.ceil(common / 1e6))
    if min_cycles > max_cycles:
        raise ValueError('这些频率的共同周期无法装入采样表：请增加点数或选择整比频率；未改变任何输出')
    cycles = max(min_cycles, min(max_cycles, max(1, math.floor(points * common / (16 * highest)))))
    repeat = common / cycles
    harmonics = [round(t['hz'] / repeat) for t in all_tones]
    # Dense reference over a fundamental period; independent of hardware table length.
    count = 32768
    clean = [math.fsum(t['peak_v'] * math.sin(math.tau*t['order']*i/count + math.radians(t['phase_deg']))
                       for t in tones) for i in range(count)]
    clean_vpp = max(clean) - min(clean)
    clean_rms = math.sqrt(math.fsum(t['peak_v']**2 for t in tones)/2)
    warnings = []
    low = .1 if mode == 'A' else .05
    if not low - 1e-8 <= clean_vpp <= .25 + 1e-8:
        warnings.append(f'被测信号 Upp={clean_vpp*1000:.3f} mV，超出题目 {low*1000:g}～250 mV；可用于扩展测试')
    if interference and not math.isclose(interference['peak_v']*2, .2, abs_tol=1e-9):
        warnings.append('干扰不是题目规定的 200 mVpp；当前为扩展测试')
    # Sum bound fixes voltage mapping across baseline/interference/mixed parts.
    scale = math.ceil((2 * math.fsum(t['peak_v'] for t in all_tones))*1000 - 1e-9)/1000
    config = validate_settings(waveform='arb', hz=repeat, vpp=scale, offset_v=0, load=settings['load'])
    part = settings.get('part', '混合信号')
    selected = all_tones
    if mode == 'C':
        if part == '仅被测信号':
            selected = tones
        elif part == '仅干扰':
            selected = [interference]
        elif part != '混合信号':
            raise ValueError('未知输出组成')
    else:
        part = '仅被测信号'
    samples = [math.fsum(t['peak_v']*math.sin(math.tau*round(t['hz']/repeat)*i/points + math.radians(t['phase_deg']))
                         for t in selected)/(scale/2) for i in range(points)]
    sample_codes(samples)
    if settings['load'] == 'HIGHZ':
        warnings.append('HIGHZ 为源设置标称值；实际 50 Ω 负载端电压约减半，请按接线与校准约定选择')
    return dict(samples=samples, config=config, mode=mode, part=part, points=points,
                repeat_hz=repeat, table_sample_rate_hz=points*repeat,
                tones=tones, interference=interference,
                clean_vpp_mv=clean_vpp*1000, clean_rms_mv=clean_rms*1000,
                warnings=warnings,
                preview_clean=clean[::32],
                output_table_vpp_mv=(max(samples)-min(samples))*scale/2*1000,
                output_table_rms_mv=math.sqrt(math.fsum(x*x for x in samples)/points)*scale/2*1000)


def preset(mode):
    return dict(mode=mode, f0_khz=50 if mode == 'A' else 125, points=8192, load='HIGHZ',
                tones=[dict(order=1, peak_mv=60 if mode == 'A' else 5, phase_deg=0),
                       dict(order=3, peak_mv=25, phase_deg=0 if mode == 'A' else 90),
                       dict(order=4, peak_mv=15 if mode == 'A' else 20, phase_deg=0)],
                interference_khz=1000, interference_vpp_mv=200,
                interference_phase_deg=0, part='混合信号')
