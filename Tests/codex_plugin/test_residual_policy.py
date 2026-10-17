"""Residual remember authority respects the effective current memory policy."""
import unittest
from residual_context_fixture import ResidualContextFixture,RC,C

class ResidualPolicyTests(unittest.TestCase):
    def fixture(self):
        f=ResidualContextFixture();self.addCleanup(f.close);return f
    def disable_remember(self,f):
        raw=f.config.read_text();needle='default_tools_approval_mode = "approve"\n'
        self.assertIn(needle,raw)
        f.config.write_text(raw.replace(needle,needle+'disabled_tools = ["remember"]\n',1))
    def test_update_permission_cannot_authorize_residual_remembers(self):
        f=self.fixture();before=f.current();self.disable_remember(f)
        configuration,_=C._backend(f.paths.base())
        allowed=C.memory_config.allowed_tools(configuration['memory'],C.READ_TOOLS|C.WRITE_TOOLS)
        self.assertIn('update',allowed);self.assertIn('recall',allowed);self.assertNotIn('remember',allowed)
        with self.assertRaisesRegex(ValueError,'remember_policy_disallows_residuals'):
            f.seal(prepare_driver=False)
        self.assertEqual(f.current(),before)
        self.assertFalse((f.run_dir/'execution-manifest.json').exists())
    def test_later_remember_policy_revocation_holds_current_execution(self):
        f=self.fixture();f.seal(prepare_driver=False);before=f.current();self.disable_remember(f)
        with self.assertRaises(ValueError):f.context.validate_marker()
        self.assertEqual(f.current(),before)
    def test_explicit_remember_permission_satisfies_profile(self):
        f=self.fixture();configuration,_=C._backend(f.paths.base())
        self.assertIs(RC._mutation_policy(configuration),True)

if __name__=='__main__':unittest.main()
