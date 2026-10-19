# INSTRUCTION: перевірка змін (Taints, Tolerations, Node Affinity, Pod Anti-Affinity)

Цей документ описує, як розгорнути кластер і перевірити, що:

- вузли з міткою `app=mysql` мають taint `app=mysql:NoSchedule`;
- MySQL StatefulSet планується лише на ці вузли (tolerations + required node affinity) і не більше одного пода на вузол (pod anti-affinity);
- Deployment `todoapp` надає перевагу вузлам з міткою `app=todoapp` (preferred node affinity) і не більше одного пода на вузол (pod anti-affinity);
- `bootstrap.sh` розгортає всі потрібні ресурси.

## 0. Передумови

Встановлені: `docker` (запущений), `kind`, `kubectl`.

```bash
docker --version
kind --version
kubectl version --client
```

## 1. Створення кластера через kind

Із кореня репозиторію:

```bash
kind create cluster --config cluster.yml
```

Перевірка, що кластер піднявся:

```bash
kubectl cluster-info
kubectl get nodes -o wide
```

Очікується: усі вузли у стані `Ready` (control-plane та worker-вузли).

## 2. Перевірка міток (Labels) і taints вузлів

```bash
kubectl get nodes --show-labels
kubectl get nodes -L app
```

Очікується: частина worker-вузлів має мітку `app=mysql`, частина — `app=todoapp`.

Перегляд taints:

```bash
kubectl describe nodes | grep -E "^Name:|Taints:"
```

або для окремого вузла:

```bash
kubectl describe node kind-worker2 | grep -A2 Taints
```

На цьому етапі вузли з `app=mysql` ще не мають taint.

## 3. Taint вузлів з міткою app=mysql

Усі вузли з міткою `app=mysql` одним командою:

```bash
kubectl taint nodes -l app=mysql app=mysql:NoSchedule
```

Або для конкретного вузла:

```bash
kubectl taint nodes kind-worker2 app=mysql:NoSchedule
```

Перевірка:

```bash
kubectl get nodes -l app=mysql -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints
```

Очікується: у кожного вузла з `app=mysql` є taint `app=mysql:NoSchedule`.

> Taint потрібно виставити **до** розгортання MySQL (або перезапустити поди після цього), щоб переконатися, що toleration працює.

## 4. Розгортання ресурсів

```bash
chmod +x bootstrap.sh
./bootstrap.sh
```

Скрипт створює namespace, ConfigMap, Secret, Service, PV/PVC, StatefulSet MySQL, Deployment todoapp, HPA та встановлює Ingress Controller, а наприкінці очікує готовності навантажень і виводить підсумок.

Ручна перевірка статусу:

```bash
kubectl -n mysql rollout status statefulset/mysql --timeout=180s
kubectl -n todoapp rollout status deployment/todoapp --timeout=180s
```

## 5. Перевірка StatefulSet (MySQL)

### 5.1. Розміщення подів

```bash
kubectl get pods -n mysql -o wide
```

Очікується:

- поди `mysql-0` і `mysql-1` у стані `Running`;
- колонка `NODE` показує **різні** вузли;
- обидва вузли мають мітку `app=mysql`.

Перевірка, що вузли відповідають мітці:

```bash
kubectl get nodes -l app=mysql
```

### 5.2. Toleration

```bash
kubectl -n mysql get statefulset mysql -o jsonpath='{.spec.template.spec.tolerations}' ; echo
```

Очікується: toleration з `key: app`, `operator: Equal`, `value: mysql`, `effect: NoSchedule`.

### 5.3. Node Affinity

```bash
kubectl -n mysql get statefulset mysql -o jsonpath='{.spec.template.spec.affinity.nodeAffinity}' ; echo
```

Очікується: `requiredDuringSchedulingIgnoredDuringExecution` з виразом `app In [mysql]`.

### 5.4. Pod Anti-Affinity

```bash
kubectl -n mysql get statefulset mysql -o jsonpath='{.spec.template.spec.affinity.podAntiAffinity}' ; echo
```

Очікується: `requiredDuringSchedulingIgnoredDuringExecution`, `labelSelector` по `app In [mysql]`, `topologyKey: kubernetes.io/hostname`.

### 5.5. Негативний тест: без toleration под не потрапляє на tainted вузол

Перевірте, що звичайний под не планується на вузол з taint:

```bash
kubectl run taint-test --image=nginx --restart=Never \
  --overrides='{"spec":{"nodeSelector":{"app":"mysql"}}}'
kubectl get pod taint-test -o wide
kubectl describe pod taint-test | grep -A5 Events
```

Очікується: под у стані `Pending`, у подіях — `node(s) had untolerated taint {app: mysql}`.

Прибрати тестовий под:

```bash
kubectl delete pod taint-test
```

### 5.6. Негативний тест: anti-affinity

Масштабування StatefulSet більше, ніж кількість вузлів з `app=mysql`:

```bash
kubectl -n mysql scale statefulset mysql --replicas=3
kubectl get pods -n mysql -o wide
kubectl -n mysql describe pod mysql-2 | grep -A5 Events
```

Очікується: `mysql-2` у `Pending` з повідомленням про `didn't match pod anti-affinity rules` (якщо вузлів з `app=mysql` лише два).

Повернути як було:

```bash
kubectl -n mysql scale statefulset mysql --replicas=2
```

## 6. Перевірка Deployment (todoapp)

### 6.1. Розміщення подів

```bash
kubectl get pods -n todoapp -o wide
kubectl get nodes -l app=todoapp
```

Очікується:

- поди `todoapp` у стані `Running`;
- кожен под на **окремому** вузлі;
- поди переважно на вузлах з міткою `app=todoapp`.

### 6.2. Node Affinity (preferred)

```bash
kubectl -n todoapp get deployment todoapp -o jsonpath='{.spec.template.spec.affinity.nodeAffinity}' ; echo
```

Очікується: `preferredDuringSchedulingIgnoredDuringExecution`, `weight: 100`, вираз `app In [todoapp]`.

### 6.3. Pod Anti-Affinity

```bash
kubectl -n todoapp get deployment todoapp -o jsonpath='{.spec.template.spec.affinity.podAntiAffinity}' ; echo
```

Очікується: `requiredDuringSchedulingIgnoredDuringExecution`, `labelSelector` по `app In [todoapp]`, `topologyKey: kubernetes.io/hostname`.

### 6.4. Перевірка anti-affinity через масштабування

```bash
kubectl -n todoapp scale deployment todoapp --replicas=2
kubectl get pods -n todoapp -o wide
```

Очікується: два поди на двох різних вузлах. Якщо реплік більше, ніж доступних вузлів, зайві поди будуть `Pending` — це очікувана поведінка правила `required` anti-affinity.

> Якщо в кластері налаштований HPA (`hpa.yml`), він може сам змінювати кількість реплік. Для чистого тесту дивіться `kubectl get hpa -n todoapp`.

## 7. Загальна перевірка

```bash
kubectl get nodes -o wide
kubectl get pods -A -o wide
kubectl get statefulset,deployment,service,pvc -n mysql
kubectl get deployment,service,pvc -n todoapp
```

Очікується: всі поди `Running`/`Ready`, PVC у стані `Bound`.

## 8. Troubleshooting

| Проблема | Що перевірити |
|---|---|
| Поди MySQL у `Pending` | `kubectl describe pod mysql-0 -n mysql` — події планувальника; чи є щонайменше 2 вузли з `app=mysql`; чи є toleration |
| Под todoapp у `Pending` під час оновлення | Required anti-affinity + `maxSurge` вимагають вільного вузла; перевірте кількість вузлів |
| PVC у `Pending` | `kubectl describe pvc -n <ns> <name>`; чи застосований `pv.yml` |
| Под у `CrashLoopBackOff` | `kubectl logs <pod> -n <ns>`; перевірте Secret/ConfigMap |
| `rollout status` перевищує таймаут | Недоступний образ, сховище або невірна конфігурація; `kubectl describe` та `kubectl get events -n <ns>` |

## 9. Очищення

```bash
kind delete cluster
```