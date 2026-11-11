"""Execute the generated player script; no browser package or inference needed."""
from pathlib import Path
import subprocess
import tempfile
import unittest
import json

from tools.interview_bench.replay import replay_html


HARNESS = r"""
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
class Element {
  constructor() { this.textContent = ''; this.hidden = false; this.handlers = {}; }
  addEventListener(type, callback) { (this.handlers[type] ||= []).push(callback); }
  emit(type) {
    for (const callback of this.handlers[type] || []) callback();
    if (typeof this['on' + type] === 'function') this['on' + type]();
  }
}
const audio = Object.assign(new Element(), {
  currentTime: 0, duration: 5, playbackRate: 1, paused: true, ended: false, seeking: false,
});
const elements = {audio, text: new Element(), events: new Element(),
                  'playback-status': new Element(), 'tail-toggle': new Element()};
let milliseconds = 0, tick;
const document = {querySelector: selector => elements[selector === 'audio' ? 'audio' : selector.slice(1)]};
const page = fs.readFileSync(process.argv[1], 'utf8');
const script = page.match(/<script>([\s\S]*?)<\/script>/)[1];
vm.runInNewContext(script, {document, performance: {now: () => milliseconds},
  setInterval: callback => {tick = callback;}});
function at(seconds) { milliseconds = seconds * 1000; tick(); }
function play() { audio.paused = false; audio.emit('play'); audio.emit('playing'); }
function end() {
  audio.currentTime = 5; audio.ended = true; audio.paused = true;
  audio.emit('pause'); audio.emit('ended');
}
const text = () => elements.text.textContent;
"""


class ReplayPlayerTests(unittest.TestCase):
    def run_case(self, actions):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            result = dict(audio_seconds=5, segments=[
                dict(text='first', returned_seconds=1),
                dict(text='second', returned_seconds=4),
                dict(text='last', returned_seconds=7),
            ], events=[dict(event='result', at_seconds=t) for t in [1, 4, 7]])
            replay_html(root, dict(id='fixture', path=str(root/'audio.wav')), result)
            script = HARNESS + '\n' + actions
            completed = subprocess.run(['node', '-e', script, str(root/'fixture.html')],
                                       capture_output=True, text=True, timeout=5)
            self.assertEqual(completed.returncode, 0, completed.stderr)

    def test_pause_does_not_reveal_future_results(self):
        self.run_case("""
          play(); audio.currentTime = 1; at(1);
          assert.equal(text(), 'first');
          audio.paused = true; audio.emit('pause'); at(100);
          assert.equal(text(), 'first');
        """)

    def test_paused_seek_updates_text_in_both_directions(self):
        self.run_case("""
          play(); audio.currentTime = 4; at(4);
          audio.paused = true; audio.emit('pause');
          audio.currentTime = 0; audio.emit('seeking'); audio.emit('seeked');
          assert.equal(text(), '');
          audio.currentTime = 4; audio.emit('seeking'); audio.emit('seeked');
          assert.equal(text(), 'first second');
        """)

    def test_playback_rate_uses_media_time(self):
        self.run_case("""
          play(); audio.playbackRate = 2; audio.emit('ratechange');
          audio.currentTime = 4; at(2);
          assert.equal(text(), 'first second');
        """)

    def test_stalled_audio_does_not_reveal_future_results(self):
        self.run_case("""
          play(); audio.currentTime = 1; at(1); audio.emit('waiting'); at(100);
          assert.equal(text(), 'first');
        """)

    def test_post_audio_results_continue_and_stop_at_recorded_end(self):
        self.run_case("""
          play(); at(5); end(); at(6);
          assert.equal(text(), 'first second'); at(7);
          assert.equal(text(), 'first second last'); at(100);
          assert.equal(text(), 'first second last');
          assert.equal(elements['tail-toggle'].hidden, true);
        """)

    def test_post_audio_wait_can_pause_resume_and_change_rate(self):
        self.run_case("""
          play(); at(5); end(); at(5.5);
          assert.equal(elements['tail-toggle'].hidden, false);
          elements['tail-toggle'].emit('click'); at(100);
          assert.equal(text(), 'first second');
          elements['tail-toggle'].emit('click');
          audio.playbackRate = 2; audio.emit('ratechange'); at(100.75);
          assert.equal(text(), 'first second last');
          audio.ended = false; audio.currentTime = 0;
          audio.emit('seeking'); audio.emit('seeked');
          assert.equal(text(), '');
          assert.equal(elements['tail-toggle'].hidden, true);
        """)


class ReplayRenderTests(unittest.TestCase):
    def fixture(self, root):
        from tools.interview_bench.schema import write_json
        run=root/'frozen-run';(run/'whole').mkdir(parents=True)
        write_json(run/'protocol.json',dict(config=dict(split='eval')))
        write_json(run/'sessions.json',[dict(id='eval-zh-1',path=str(root/'local.wav'))])
        write_json(run/'summary.json',dict(whole=dict(sessions=[dict(id='eval-zh-1')],rows=1)))
        write_json(run/'whole/eval-zh-1.json',dict(audio_seconds=5,
                   segments=[dict(text='hello',returned_seconds=7)],
                   events=[dict(event='result',at_seconds=7)]))
        return run

    def test_render_existing_events_without_audio_models_or_source_changes(self):
        from tools.interview_bench.replay import render_run
        from tools.interview_bench.schema import sha
        with tempfile.TemporaryDirectory() as d:
            root=Path(d);run=self.fixture(root);output=root/'view'
            before={str(p.relative_to(run)):sha(p) for p in run.rglob('*') if p.is_file()}
            render_run(run,output)
            self.assertEqual(before,{str(p.relative_to(run)):sha(p) for p in run.rglob('*') if p.is_file()})
            protocol=json.loads((output/'render-protocol.json').read_text())
            self.assertEqual(protocol['additional_inference_runs'],0)
            self.assertEqual(protocol['source_results_sha256'],{'whole/eval-zh-1.json':before['whole/eval-zh-1.json']})
            self.assertTrue((output/'whole/eval-zh-1.html').is_file())
            for path,digest in protocol['rendered_files_sha256'].items():self.assertEqual(sha(output/path),digest)
            with self.assertRaises(FileExistsError):render_run(run,output)

    def test_render_rejects_outputs_inside_frozen_run_and_wrong_session_ids(self):
        from tools.interview_bench.replay import render_run
        from tools.interview_bench.schema import write_json
        with tempfile.TemporaryDirectory() as d:
            root=Path(d);run=self.fixture(root)
            with self.assertRaises(ValueError):render_run(run,run/'new-view')
            self.assertFalse((run/'new-view').exists())
            write_json(run/'summary.json',dict(whole=dict(sessions=[dict(id='unexpected')],rows=1)))
            with self.assertRaises(ValueError):render_run(run,root/'wrong')
            self.assertFalse((root/'wrong').exists())
