$pod = kubectl get pods -n pacman | select-string -Pattern "mongo-\w*\-\w*" | ForEach-Object { $_.Matches } | ForEach-Object { $_.Value }

kubectl exec $pod -n pacman -it -- /bin/bash -c "mongo -u blinky -p pinky pacman"

show dbs
show collections
db.highscore.find()
db.highscore.remove({})