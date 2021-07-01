local baseDomain = 'k8s.qt.rs';
local domain = 'monitoring.' + baseDomain;

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
      'external-dns.alpha.kubernetes.io/target': baseDomain,
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

local main = import 'kube-prometheus/main.libsonnet';

local kp =
  main +
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
        plugins: ['grafana-piechart-panel', 'grafana-polystat-panel', 'snuids-trafficlights-panel'],
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
              enable_login_token: false,
            },
            panels+: {
              disable_sanitize_html: true,
            },
            server+: {
              domain: domain,
              root_url: 'https://' + domain,
            },
            users+: {
              allow_sign_up: false,
              auto_assign_org: true,
              auto_assign_org_role: 'Editor',
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

      # Add required accesses for the dashboard sidecar?
      clusterRole+: {
        rules+: [
          {
            apiGroups: [''],
            resources: ['pods', 'endpoints', 'services'],
            /* verbs: ['get', 'watch', 'list'], */
            verbs: ['get', 'watch', 'list'],
          },
        ],
      },
    },

    ingress+:: {
      monitoring: ingress('monitoring', $.values.common.namespace, [domain], [
        {
          host: domain,
          http: {
            paths: [{
              path: '/',
              pathType: 'Prefix',
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
        },
        {
          host: 'alertmanager' + baseDomain,
          http: {
            paths: [{
              path: '/',
              pathType: 'Prefix',
              backend: {
                service: {
                  name: 'alertmanager-main',
                  port: {
                    name: 'http',
                  },
                },
              },
            }],
          },
        },
        {
          host: 'prometheus' + baseDomain,
          http: {
            paths: [{
              path: '/',
              pathType: 'Prefix',
              backend: {
                service: {
                  name: 'prometheus-k8s',
                  port: {
                    name: 'http',
                  },
                },
              },
            }],
          },
        }
      ])
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
// Last, we enable the grafana configmap sidecar to provision dashboards
local modifiedGrafana = kp.grafana + {
  local g = kp.grafana,
  deployment+: {
    spec+: {
      strategy: { type: 'Recreate' },
      template+: {
        spec+: {
          containers: [
            (container + {
              envFrom+: [{ secretRef: { name: 'grafana-admin-credentials' } }],
              volumeMounts+: [
                {
                  name: 'sc-dashboard-volume',
                  mountPath: '/tmp/dashboards',
                },
              ],
            })
            for container in g.deployment.spec.template.spec.containers
          ] + [{
            name: 'grafana-sc-dashboard',
            image: 'quay.io/kiwigrid/k8s-sidecar:1.12.2',
            imagePullPolicy: 'IfNotPresent',
            resources: {},
            env: [
              { name: 'METHOD', value: 'WATCH' },
              { name: 'LABEL', value: 'grafana_dashboard' },
              { name: 'FOLDER', value: '/tmp/dashboards/' },
              { name: 'RESOURCE', value: 'both' },
              /* { name: 'UNIQUE_FILENAMES', value: false }, */
              { name: 'NAMESPACE', value: 'ALL' },
            ],
            volumeMounts: [{
              name: 'sc-dashboard-volume',
              mountPath: '/tmp/dashboards',
            }],
          }],
          volumes: [
            if volume.name == 'grafana-storage'
            then {
              name: volume.name,
              persistentVolumeClaim: { claimName: 'grafana-storage', readOnly: false },
            }
            else volume
            for volume in g.deployment.spec.template.spec.volumes
          ] + [
            {
              name: 'sc-dashboard-volume',
              emptyDir: {},
            },
            {
              name: 'sc-dashboard-provider',
              configMap: { name: 'grafana-config-dashboards' },
            }
          ],
        },
      },
    },
  },
  dashboardSources+: {
    data+: {
      'provider.yaml': |||
        apiVersion: 1
        providers:
        - name: 'sidecarProvider'
          orgId: 1
          type: 'file'
          disableDeletion: false
          allowUiUpdates: false
          updateIntervalSeconds: 30
          options:
            foldersFromFilesStructure: false
            path: '/tmp/dashboards/'
      |||,
    },
  },
  'dashboardSidecar-clusterRole'+: {
    apiVersion: 'rbac.authorization.k8s.io/v1',
    kind: 'ClusterRole',
    metadata: {
      name: 'grafana',
    },
    rules: [{
      apiGroups: [''],
      resources: ['configmaps', 'secrets'],
      verbs: ['get', 'watch', 'list'],
    }],
  },
  'dashboardSidecar-clusterRoleBinding'+: {
    apiVersion: 'rbac.authorization.k8s.io/v1',
    kind: 'ClusterRoleBinding',
    metadata: {
      name: 'grafana',
    },
    subjects: [{
      kind: 'ServiceAccount',
      name: 'grafana',
      namespace: kp.values.common.namespace,
    }],
    roleRef: {
      apiGroup: 'rbac.authorization.k8s.io',
      kind: 'ClusterRole',
      name: 'grafana',
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
  { ['kubernetes-' + name]: kp.kubernetesControlPlane[name] for name in std.objectFields(kp.kubernetesControlPlane) } +
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
