for res in deployment statefulset; do
  for name in $(kubectl get $res -n argocd -o name); do
    kubectl patch $name -n argocd -p '{"spec":{"template":{"spec":{"nodeSelector":{"workload":"gitops"}}}}}'
  done
done
