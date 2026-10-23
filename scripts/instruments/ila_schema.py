"""Canonical names for legacy live probes and version-2 debug snapshots."""
ALIASES = {
    'debug_measurement_valid':'measurement_valid', 'debug_vpp':'vpp_out',
    'debug_rms':'vrms_out', 'debug_fundamental':'amp_f1_out',
    'debug_fundamental_bin':'max_index_out', 'debug_component_bins':'diagnostic_bins',
    'debug_component_count':'component_count',
    'debug_component_magnitudes':'component_magnitudes', 'debug_frame_id':'frame_id',
    'debug_calibration_epoch':'calibration_epoch', 'debug_metadata':'snapshot_metadata',
}


def canonical_name(name):
    leaf=name.split(':')[0].split('/')[-1].split('[')[0]
    return ALIASES.get(leaf,leaf)
