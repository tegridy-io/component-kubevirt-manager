// main template for kubevirt-manager
local com = import 'lib/commodore.libjsonnet';
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';

// The hiera parameters for the component
local inv = kap.inventory();
local params = inv.parameters.kubevirt_manager;
local isOpenshift = std.startsWith(inv.parameters.facts.distribution, 'openshift');
local app_name = 'kubevirt-manager';


// Common Labels
local labelsKubevirt = {
  'app.kubernetes.io/name': app_name,
  'kubevirt-manager.io/version': params.images.kubevirt_manager.tag,
};

// Namespace
local namespace = kube.Namespace(params.namespace.name) {
  metadata+: {
    annotations+: params.namespace.annotations,
    labels+: {
      // Configure the namespaces so that the OCP4 cluster-monitoring
      // Prometheus can find the servicemonitors and rules.
      [if isOpenshift then 'openshift.io/cluster-monitoring']: 'true',
    } + com.makeMergeable(params.namespace.labels),
  },
};

// RBAC from bundled upstream
local clusterScoped = [
  'ClusterRole',
  'ClusterRoleBinding',
  'CustomResourceDefinition',
  'MutatingWebhookConfiguration',
  'Namespace',
  'PriorityClass',
  'ValidatingWebhookConfiguration',
];
local bindings = [
  'ClusterRoleBinding',
  'RoleBinding',
];

local keep = [
  'ClusterRoleBinding',
  'RoleBinding',
  'ClusterRole',
  'Role',
  'ServiceAccount',
];

local patchNamespace(resource) = resource {
  metadata+: {
    labels+: {
      [if resource.kind != 'CustomResourceDefinition' then 'app.kubernetes.io/managed-by']: 'commodore',
      'kubevirt-manager.io/version': params.images.kubevirt_manager.tag,
    },
    [if !std.member(clusterScoped, resource.kind) then 'namespace']: params.namespace.name,
  },
  [if std.member(bindings, resource.kind) then 'subjects']: std.map(
    function(it) it { namespace: params.namespace.name },
    resource.subjects
  ),
};

local manifests = std.filter(
  function(it) std.member(keep, it.kind),
  std.parseJson(kap.yaml_load_stream('kubevirt-manager/manifests/dashboard-main/bundled.yaml'))
);

local rbac = std.map(
  patchNamespace,
  manifests
);

local sa = std.filter(
  function(it) it.kind == 'ServiceAccount',
  rbac
);

// Container
local containerKubevirt = kube.Container(app_name) {
  image: '%(registry)s/%(repository)s:%(tag)s' % params.images.kubevirt_manager,
  ports_:: {
    [if !params.oidc.enabled then 'http']: { containerPort: 8080 },
  },
  resources: params.resources.kubevirt_manager,
  securityContext: {
    allowPrivilegeEscalation: false,
    readOnlyRootFilesystem: true,
    runAsUser: 10000,
    runAsGroup: 30000,
  },
  volumeMounts_:: {
    cache: { mountPath: '/var/cache/nginx' },
    run: { mountPath: '/var/run' },
  },
};

local containerOauthProxy = kube.Container('oauth-proxy') {
  image: '%(registry)s/%(repository)s:%(tag)s' % params.images.oidc_proxy,
  env_:: {
    OAUTH2_PROXY_REDIRECT_URL: 'https://%s/oauth2/callback' % params.ingress.url,
    OAUTH2_PROXY_HTTP_ADDRESS: 'http://0.0.0.0:4180',
    OAUTH2_PROXY_UPSTREAMS: 'http://localhost:8080',
    OAUTH2_PROXY_EMAIL_DOMAINS: '*',
  } + {
    [std.asciiUpper('OAUTH2_PROXY_' + name)]: params.oidc.env[name]
    for name in std.objectFields(params.oidc.env)
  },
  ports_:: {
    http: { containerPort: 4180 },
  },
};

// Deployment
local deployment = kube.Deployment(app_name) {
  metadata+: {
    labels: {
      'app.kubernetes.io/managed-by': 'commodore',
    } + labelsKubevirt,
    namespace: params.namespace.name,
  },
  spec+: {
    selector: {
      matchLabels: labelsKubevirt,
    },
    replicas: 1,
    strategy: { type: 'Recreate' },
    template+: {
      metadata: { labels: labelsKubevirt },
      spec+: {
        containers: if params.oidc.enabled then
          [ containerOauthProxy, containerKubevirt ]
        else
          [ containerKubevirt ],
        serviceAccountName: sa[0].metadata.name,
        restartPolicy: 'Always',
        volumes_:: {
          cache: { emptyDir: {} },
          run: { emptyDir: {} },
        },
      },
    },
  },
};

// Ingress
local service = kube.Service(app_name) {
  metadata+: {
    labels: {
      'app.kubernetes.io/managed-by': 'commodore',
    } + labelsKubevirt,
    namespace: params.namespace.name,
  },
  target_pod:: deployment.spec.template,
};

local ingress = kube._Object('networking.k8s.io/v1', 'Ingress', app_name) {
  metadata+: {
    annotations+: params.ingress.annotations,
    labels+: {
      'app.kubernetes.io/managed-by': 'commodore',
    } + labelsKubevirt,
    namespace: params.namespace.name,
  },
  spec+: {
    rules: [ {
      host: params.ingress.url,
      http: {
        paths: [ {
          backend: {
            service: {
              name: app_name,
              port: {
                name: 'http',
              },
            },
          },
          path: '/',
          pathType: 'Prefix',
        } ],
      },
    } ],
    [if params.ingress.tls then 'tls']: [ {
      hosts: [ params.ingress.url ],
      secretName: app_name + '-tls',
    } ],
  },
};

// Define outputs below
{
  '00_namespace': namespace,
  '10_deployment': [ deployment ] + rbac,
  '20_service': service,
  [if params.ingress.enabled then '20_ingress']: ingress,
}
