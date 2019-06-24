#!/bin/bash -e

x=4
while [ $x -gt 0 ]; do
    back_end=$(ps -A -o args | grep port-forward | grep -v grep | awk '{print $3}')
    if [[ -z $(ps -C "kubectl port-forward wordpress-wordpress" | tail -n +2 | awk '{print $1}') ]]
      then
       healty_pod=$(kubectl get pods | grep wordpress-wordpress | grep 1/1 | grep Running | awk '{print $1}' | head -n 1)
        if [[ -n $healty_pod ]]
         then
           nohup kubectl port-forward $healty_pod 80:80 &>/dev/null &
        fi
      else
       if [[ -z $(kubectl get pods | grep $back_end | grep 1/1 | grep Running) ]]
         then
           kill -9 $(ps -C "kubectl port-forward wordpress-wordpress" | tail -n +2 | awk '{print $1}')
         fi
    fi
    sleep 10
    x=$(($x-1))
done