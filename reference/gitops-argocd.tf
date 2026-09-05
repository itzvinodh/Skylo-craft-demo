############################################################################
# Reference only — see reference/README.md. Not part of the graded
# deliverable. Day-2 GitOps sketch: Git push -> ArgoCD in-cluster -> pulls
# image from ECR -> progressive rollout. Kept as a talking point for "how
# would you actually operate this," with the fabricated cost/latency
# figures from the original draft removed.
############################################################################

resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  namespace        = "argocd"
  create_namespace = true

  # ArgoCD runs entirely inside the private-app subnets — it polls GitHub
  # over HTTPS outbound (via NAT) and pulls images from ECR over the
  # interface VPC endpoint, so nothing about the deploy path needs public
  # ingress. Only the customer NLB (sg-nlb-pattern.tf) is internet-facing.
}

resource "kubectl_manifest" "upf_app" {
  yaml_body = <<-YAML
    apiVersion: argoproj.io/v1alpha1
    kind: Application
    metadata:
      name: upf
      namespace: argocd
    spec:
      project: default
      source:
        repoURL: https://github.com/skylo/5g-core
        targetRevision: prod
        helm:
          values: |
            image: <ecr_repo_url>:v2
            resources:
              limits: { cpu: 4, memory: 8Gi }
      destination:
        server: https://kubernetes.default.svc
        namespace: upf
      syncPolicy:
        automated: { prune: true, selfHeal: true }
        syncOptions: ["CreateNamespace=true"]
  YAML
}

# Talking points, stated as reasoning rather than numbers I can't back up:
#
# - Git push -> ArgoCD sync replaces manual kubectl apply, which matters
#   for a telco core specifically because it removes the "someone fat-
#   fingered a kubectl command against prod" failure mode, and gives an
#   audit trail (every prod change is a Git commit) that's directly useful
#   for SOC 2 change-management evidence.
# - Argo Rollouts for canary (1% -> 100%) on the control-plane services
#   is the right call; I would NOT canary the UPF data plane the same way
#   without first checking how session affinity behaves mid-rollout —
#   dropping live sessions during a canary step is worse than the outage
#   you were trying to avoid. That's a real open question, not solved
#   here.
# - Pulling from ECR via an interface VPC endpoint instead of over NAT/IGW
#   avoids per-GB NAT data-processing charges on every image pull and
#   keeps the pull path off the public internet entirely — real reasons,
#   without attaching a specific dollar figure I didn't measure.
