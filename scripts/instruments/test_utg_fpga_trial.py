"""Fixed fixture/evaluation/session tests, no real instrument or JTAG."""
import copy
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from contextlib import nullcontext

import utg_fpga_trial as trial


class TestTrial(unittest.TestCase):
    def test_fixture_envelope_and_weak_fundamental(self):
        for case in ('sine','harmonic','strong_harmonic'):
            table,ref=trial.fixture(case)
            self.assertEqual(table['vpp'],0.1)
            self.assertLessEqual(sum(t['vpp'] for t in table['tones']),0.1+1e-12)
            self.assertGreaterEqual(ref['vpp_mv'],50)
        table,ref=trial.fixture('strong_harmonic')
        self.assertEqual(ref['fundamental_hz'],50000)
        self.assertLess(table['tones'][0]['vpp'],table['tones'][1]['vpp'])

    def test_evaluate_bins_faults_and_amplitudes(self):
        _,ref=trial.fixture('sine')
        raw=dict(vpp_out=100000,vrms_out=35355,amp_f1_out=50000,max_index_out=200,frequency_hz=100000)
        inspect=dict(diagnostic=dict(controls=4,signal_valid=True,error_code=0,acquisition_fault=False),
                     completed_packet_samples=1,candidate_bins=[200,0,0],last_registers=copy.deepcopy(raw))
        gains=dict(vpp=65536,rms=65536,fft=65536)
        self.assertTrue(trial.evaluate(raw,inspect,ref,gains)['nominal_consistency_pass'])
        inspect['component_snapshot']=dict(count=1,bins=[200,0,0],magnitudes_raw=[50000,0,0],
            signal_valid=True,mode=1,frame_id=8,calibration_epoch=3)
        evaluated=trial.evaluate(raw,inspect,ref,gains)
        self.assertTrue(evaluated['all_component_amplitudes_observed'])
        self.assertEqual(evaluated['component_errors_mv'],[0])
        inspect['component_snapshot']['magnitudes_raw'][0]=60000
        self.assertFalse(trial.evaluate(raw,inspect,ref,gains)['nominal_consistency_pass'])
        del inspect['component_snapshot']
        inspect['candidate_bins']=[201,0,0]
        self.assertFalse(trial.evaluate(raw,inspect,ref,gains)['validity_pass'])
        inspect['candidate_bins']=[200,0,0];inspect['diagnostic']['acquisition_fault']=True
        self.assertFalse(trial.evaluate(raw,inspect,ref,gains)['validity_pass'])

    def fake_generator(self):
        class Fake:
            identity='FAKE';log=[]
            def __init__(self):self.on=False;self.stops=[]
            def __enter__(self):return self
            def __exit__(self,*args):pass
            def settings(self,ch):
                return dict(waveform='SINE',mode='CONTINUE',unit='VPP',load_ohm=10000,
                            hz=100000,vpp=0.1,offset_v=0,phase_deg=0,output=self.on if ch==1 else False)
            def configure_sine(self,*args):return self.settings(1)
            def output_on(self,*args):self.on=True
            def emergency_off(self,ch):self.stops.append(ch);self.on=False;return dict(acknowledged=True)
        return Fake()

    def test_capture_failure_finally_disables_both_and_persists(self):
        fake=self.fake_generator()
        with tempfile.TemporaryDirectory() as td:
            p=Path(td);(p/'vivado').touch();(p/'ltx').touch()
            with patch.object(trial,'UTG932',return_value=fake),patch.object(trial,'ResourceLock',return_value=nullcontext()),\
                 patch.object(trial.time,'sleep'),patch.object(trial,'capture_ila',side_effect=RuntimeError('capture failed')):
                with self.assertRaisesRegex(RuntimeError,'capture failed'):
                    trial.run('sine',p/'new',p/'vivado',p/'ltx')
            report=json.loads((p/'new/session.json').read_text())
            self.assertEqual(report['status'],'failed')
            self.assertTrue(report['output_off_confirmed'])
            self.assertEqual(fake.stops,[1,2])

    def test_connection_failure_is_not_left_running(self):
        with tempfile.TemporaryDirectory() as td:
            p=Path(td);(p/'vivado').touch();(p/'ltx').touch()
            with patch.object(trial,'ResourceLock',return_value=nullcontext()),\
                 patch.object(trial,'UTG932',side_effect=RuntimeError('unavailable')):
                with self.assertRaisesRegex(RuntimeError,'unavailable'):
                    trial.run('sine',p/'new',p/'vivado',p/'ltx')
            self.assertEqual(json.loads((p/'new/session.json').read_text())['status'],'failed')

    def test_unconfirmed_off_is_failure_even_after_good_capture(self):
        fake=self.fake_generator()
        fake.emergency_off=lambda ch:dict(acknowledged=False,sent=True)
        with tempfile.TemporaryDirectory() as td:
            p=Path(td);(p/'vivado').touch();(p/'ltx').touch()
            with patch.object(trial,'UTG932',return_value=fake),patch.object(trial,'ResourceLock',return_value=nullcontext()),\
                 patch.object(trial.time,'sleep'),patch.object(trial,'capture_ila',return_value={}),\
                 patch.object(trial,'inspect_capture',return_value={}),\
                 patch.object(trial,'evaluate',return_value=dict(nominal_consistency_pass=True)):
                with self.assertRaisesRegex(RuntimeError,'OFF unconfirmed'):
                    trial.run('sine',p/'new',p/'vivado',p/'ltx',captures=1)
            report=json.loads((p/'new/session.json').read_text())
            self.assertEqual(report['status'],'failed')
            self.assertFalse(report['output_off_confirmed'])

    def test_existing_results_are_not_overwritten(self):
        with tempfile.TemporaryDirectory() as td:
            path=Path(td);(path/'session.json').write_text('{"status":"running"}')
            with self.assertRaises(FileExistsError):trial.run('sine',path,'unused','unused')
            self.assertEqual((path/'session.json').read_text(),'{"status":"running"}')

    def test_archive_preserves_failed_or_unknown_shutdown(self):
        with tempfile.TemporaryDirectory() as td:
            p=Path(td);source=p/'source';source.mkdir()
            (source/'session.json').write_text(json.dumps(dict(status='failed',
                output_off_confirmed=False,captures=[],case='sine')))
            result=trial.archive_sessions([source],p/'archive.json')
            self.assertFalse(result['overall_pass'])
            self.assertEqual(result['sessions'][0]['status'],'failed')
            with self.assertRaises(FileExistsError):trial.archive_sessions([source],p/'archive.json')


if __name__=='__main__':unittest.main()
