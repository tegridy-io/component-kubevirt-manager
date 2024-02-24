local kap = import 'lib/kapitan.libjsonnet';
local inv = kap.inventory();
local params = inv.parameters.kubevirt_manager;
local argocd = import 'lib/argocd.libjsonnet';

local app = argocd.App('kubevirt-manager', params.namespace.name);

{
  'kubevirt-manager': app {
    spec+: {
      syncPolicy+: {
        syncOptions+: [
          'ServerSideApply=true',
        ],
      },
    },
  },
}
