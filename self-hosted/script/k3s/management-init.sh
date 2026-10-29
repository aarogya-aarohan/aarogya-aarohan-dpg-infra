# Install ArgoCD and all the relevant staging to argo cd manually
# Few of them referenced in the code are
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Bootstrap server to include staging with staging related tool
# Add the cluster using the argocd cli

#Login to cli
# Set the Kubectl config default namespace to argocd so argocd cli will work by default
# sudo kubectl config set-context --current --namespace=argocd
# export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
argocd login cd.argoproj.io --core