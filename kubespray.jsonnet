local domain = 'k8s.qt.rs';

local ingress(name, namespace, hosts, rules) = {
  apiVersion: 'networking.k8s.io/v1',
  kind: 'Ingress',
  metadata: {
    name: name,
    namespace: namespace,
    annotations: {
      'cert-manager.io/cluster-issuer': 'letsencrypt-prod',
      'traefik.ingress.kubernetes.io/router.middlewares': 'traefik-forward-auth@kubernetescrd',
      'traefik.ingress.kubernetes.io/router.tls': 'true',
      'external-dns.alpha.kubernetes.io/target': 'k8s.qt.rs',
    },
  },
  spec: {
    ingressClassName: 'traefik',
    tls: [{
      hosts: hosts,
      secretName: name + '-k8s-qt-rs',
    }],
    rules: rules,
  },
};

local kp =
  (import 'kube-prometheus/main.libsonnet') +
  // Uncomment the following imports to enable its patches
  // (import 'kube-prometheus/addons/anti-affinity.libsonnet') +
  // (import 'kube-prometheus/addons/managed-cluster.libsonnet') +
  // (import 'kube-prometheus/addons/node-ports.libsonnet') +
  // (import 'kube-prometheus/addons/static-etcd.libsonnet') +
  // (import 'kube-prometheus/addons/thanos-sidecar.libsonnet') +
  // (import 'kube-prometheus/addons/custom-metrics.libsonnet') +
  // (import 'kube-prometheus/addons/external-metrics.libsonnet') +
  {
    values+:: {
      kubePrometheus+: {
        platform: 'kubespray',
      },
      common+: {
        namespace: 'monitoring',
      },
      grafana+: {
        plugins: ['grafana-piechart-panel'],
        config+: {
          sections+: {
            analytics+: {
              reporting_enabled: false,
            },
            'auth.anonymous'+: {
              enabled: false,
            },
            'auth.basic'+: {
              enabled: false,
            },
            'auth.proxy'+: {
              enabled: true,
              header_name: 'X-Forwarded-User',
              header_property: 'username',
              // whitelist: ''
            },
            server+: {
              domain: 'monitoring.' + domain,
              root_url: 'https://monitoring.' + domain,
            },
            users+: {
              allow_sign_up: false,
            },
          },
        },
      },
    },

    prometheus+:: {
      prometheus+: {
        spec+: {
          retention: '30d',
          storage: {
            volumeClaimTemplate: {
              apiVersion: 'v1',
              kind: 'PersistentVolumeClaim',
              spec: {
                storageClassName: 'openebs-sc-iscsi',
                accessModes: ['ReadWriteOnce'],
                resources: { requests: { storage: '100Gi' } },
              },
            },
          },
          serviceMonitorNamespaceSelector: {
            matchLabels+: {
              prometheus: 'k8s',
            },
          },
        },
      },
    },

    ingress+:: {
      monitoring: ingress('monitoring', $.values.common.namespace, ['monitoring.' + domain], [{
        host: 'monitoring.' + domain,
        http: {
          paths: [{
            backend: {
              service: {
                name: 'grafana',
                port: {
                  name: 'http',
                },
              },
            },
          }],
        },
      }])
    },

    kubePrometheus+:: {
      namespace+: {
        metadata+: {
          labels+: {
            prometheus: 'k8s',
          },
        },
      },
    },
  };

// We need to inject some secrets as environment variables
// We can't use a configMap because there's already a generated config
// We also want temporary stateful storage with a PVC
local modifiedGrafana = kp.grafana + {
  local g = kp.grafana,
  deployment+: {
    spec+: {
      strategy: { type: 'Recreate' },
      template+: {
        spec+: {
          containers: [
            (container + {
              envFrom+: [{ secretRef: { name: 'grafana-admin-credentials' } }]
            })
            for container in g.deployment.spec.template.spec.containers
          ],
          volumes: [
            if volume.name == 'grafana-storage'
            then {
              name: volume.name,
              persistentVolumeClaim: { claimName: 'grafana-storage', readOnly: false },
            }
            else volume
            for volume in g.deployment.spec.template.spec.volumes
          ]
        },
      },
    },
  },
  pvc: {
    apiVersion: 'v1',
    kind: 'PersistentVolumeClaim',
    metadata: {
      name: 'grafana-storage',
      namespace: kp.values.common.namespace,
    },
    spec: {
      storageClassName: 'openebs-sc-iscsi',
      accessModes: ['ReadWriteOnce'],
      resources: { requests: { storage: '10Gi' } },
    },
  },
};

local manifests =
  { 'setup/0namespace-namespace': kp.kubePrometheus.namespace } +
  {
    ['setup/prometheus-operator-' + name]: kp.prometheusOperator[name]
    for name in std.filter((function(name) name != 'serviceMonitor' && name != 'prometheusRule'), std.objectFields(kp.prometheusOperator))
  } +
  // serviceMonitor is separated so that it can be created after the CRDs are ready
  { 'prometheus-operator-serviceMonitor': kp.prometheusOperator.serviceMonitor } +
  { 'prometheus-operator-prometheusRule': kp.prometheusOperator.prometheusRule } +
  { 'kube-prometheus-prometheusRule': kp.kubePrometheus.prometheusRule } +
  { ['alertmanager-' + name]: kp.alertmanager[name] for name in std.objectFields(kp.alertmanager) } +
  { ['grafana-' + name]: modifiedGrafana[name] for name in std.objectFields(modifiedGrafana) } +
  { ['kube-state-metrics-' + name]: kp.kubeStateMetrics[name] for name in std.objectFields(kp.kubeStateMetrics) } +
  { ['node-exporter-' + name]: kp.nodeExporter[name] for name in std.objectFields(kp.nodeExporter) } +
  { ['prometheus-' + name]: kp.prometheus[name] for name in std.objectFields(kp.prometheus) } +
  { ['prometheus-adapter-' + name]: kp.prometheusAdapter[name] for name in std.objectFields(kp.prometheusAdapter) } +
  { [name + '-ingress']: kp.ingress[name] for name in std.objectFields(kp.ingress) };

local kustomizationResourceFile(name) = './manifests/' + name + '.yaml';
local strContains(str, substr) = std.length(std.findSubstr(substr, str)) > 0;
local kustomization = {
  apiVersion: 'kustomize.config.k8s.io/v1beta1',
  kind: 'Kustomization',
  local resources = std.map(kustomizationResourceFile, std.objectFields(manifests)),
  resources: [
    file for file in resources if strContains(file, 'manifests/setup/')
  ] + [
    file for file in resources if ! strContains(file, 'manifests/setup/')
  ],
};

manifests {
  '../kustomization': kustomization,
}
