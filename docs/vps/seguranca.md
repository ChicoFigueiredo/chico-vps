# Endurecimento de segurança da VPS

> Aplicado em 09/AGO/2026, depois do ransomware que apagou o banco do basilio em 04/JUL.
> Arquivos reais: [`vps/seguranca/`](../../vps/seguranca/)

---

## Primeiro: corrigindo o alvo

O pedido foi "proteger o endpoint com senha no nginx", pensando no `8642` do hermes.
**Aquele endpoint nunca esteve na internet** — e é importante saber disso, porque
protegê-lo não teria adiantado nada contra o tipo de ataque que já aconteceu.

| Porta | Onde escuta | Alcançável de fora? |
|---|---|---|
| `8642` (hermes-agent) | rede docker `hermes-net` | **não** — nem pelo host, desde 09/AGO |
| `8787` (hermes-webui) | `127.0.0.1` do host | **não diretamente** — só via nginx |
| `443` (nginx) | `0.0.0.0` | **sim** — é a única porta web pública |

O que estava exposto era `https://beth.chicofigueiredo.com.br`, servido pelo nginx. A
proteção tinha que entrar ali.

E o vetor do ataque de julho não foi nenhum desses: foi o **phpMyAdmin publicado em
`0.0.0.0:8095` com usuário e senha pré-preenchidos no compose** — quem abrisse o IP na
porta caía logado no banco. Esse container não existe mais.

---

## As quatro camadas, da borda para dentro

### 1. Basic auth do nginx, antes da webui

```nginx
location / {
    auth_basic "beth";
    auth_basic_user_file /etc/nginx/beth.htpasswd;
    ...
}
```

Usuário `chico`, senha em bcrypt (`htpasswd -B`). Mesmo desenho que já protegia o focus e
o ia-monitor.

**Por que somar isto ao login que a webui já tem.** São camadas independentes: uma falha
de autenticação na webui (bug, bypass, sessão vazada) não basta para chegar ao agente,
porque o nginx recusa antes de repassar. E o custo de uma camada de senha estática é
próximo de zero.

Verificado:

| | |
|---|---|
| sem credencial | `HTTP 401` |
| com credencial | `HTTP 302` (a webui então pede o login dela) |
| handshake WebSocket | atravessa — o chat continua funcionando |

> ⚠️ O WebSocket **precisa** passar pelo basic auth. O navegador reenvia o header na
> requisição de upgrade, então funciona — mas é o primeiro lugar a olhar se o chat parar
> de transmitir token a token.

### 2. Rate limit

```nginx
# /etc/nginx/conf.d/rate-limit.conf
limit_req_zone $binary_remote_addr zone=beth_zone:10m rate=20r/s;
limit_req_status 429;
```

```nginx
limit_req zone=beth_zone burst=40 nodelay;
```

20 req/s por IP com rajada de 40. A webui faz várias requisições por interação, então o
teto é alto o bastante para não atrapalhar o uso normal — o que ele corta é a cadência de
quem tenta senha em série.

> 💡 `limit_req_zone` **tem que viver no contexto `http`**, não dentro de `server{}`. Por
> isso mora em `conf.d/` e não no vhost.

### 3. fail2ban — banimento automático

Três jails novas, além da `sshd` que já existia:

| Jail | O que detecta | Limite | Banimento |
|---|---|---|---|
| `nginx-http-auth` | senha errada no basic auth | 10 em 10 min | 1 h |
| `nginx-limit-req` | quem estoura o rate limit | 10 em 10 min | 1 h |
| `nginx-botsearch` | varredura por caminhos de CMS/admin | 5 em 10 min | 6 h |

> 💡 **Por que 10 e não 5 no `nginx-http-auth`.** Começou em 5 e me trancou do lado de
> fora duas vezes durante os próprios testes. Um bot faz milhares de tentativas e cai em
> qualquer limite; quem erra 5 vezes é gente digitando. Com a senha em bcrypt de 28
> caracteres, o risco real não é força bruta — é auto-bloqueio.

### O sintoma que engana

**Um IP banido não recebe "acesso negado": recebe silêncio.** O firewall descarta o
pacote, o navegador fica girando e a página nunca carrega — que é exatamente o que se vê
quando um container caiu.

Antes de investigar container, cheque o banimento:

```bash
fail2ban-client status nginx-http-auth | grep 'Banned IP list'
```

Aconteceu em 09/AGO/2026: os testes de senha errada baniram o IP de casa, e a conclusão
imediata foi "o docker do hermes caiu" — os 8 containers estavam no ar o tempo todo.

A `nginx-botsearch` é a que responde diretamente ao ataque de julho: é o padrão de bot que
varre `/phpmyadmin`, `/wp-admin`, `/admin` procurando painel aberto.

> ⚠️ **A pegadinha que custou o diagnóstico:** o Ubuntu define `backend = systemd`
> globalmente para o fail2ban. O nginx grava em **arquivo**, não no journal — com o padrão,
> o `logpath` é ignorado e a jail fica lendo um journal que nunca terá aquelas linhas. Ela
> aparece como `enabled` e ativa, contando zero para sempre.
>
> A correção é `backend = auto` em cada jail. O sintoma de que está errado:
> ```
> fail2ban-client get nginx-http-auth logpath   →  No file is currently monitored
> ```

Testado de verdade: 6 tentativas com senha errada → IP banido, acesso cortado; depois do
`unbanip`, acesso normal restaurado.

**Se você se banir por errar a senha:**

```bash
ssh root@ssh.chico-figueiredo.com.br   # o SSH usa outra jail, e é por chave — continua entrando
fail2ban-client status nginx-http-auth
fail2ban-client set nginx-http-auth unbanip SEU.IP.AQUI
```

> ⚠️ **`systemctl restart fail2ban` pode te banir de novo.** Ao subir, ele reescaneia o
> log dentro da `findtime` e reencontra as falhas antigas — inclusive as que motivaram o
> unban que você acabou de fazer. Se precisar reiniciar depois de errar a senha, espere a
> `findtime` (10 min) passar, ou desbanhe outra vez logo em seguida.

> 💡 **Para conferir uma senha sem gerar 401**, teste contra o arquivo em vez do nginx —
> não alimenta o fail2ban:
> ```bash
> printf '%s' 'a-senha' | htpasswd -iv /etc/nginx/beth.htpasswd chico
> #   "Password for user chico correct."  ou  "password verification failed"
> ```

### 4. Superfície removida

O `hermes-agent` não publica mais porta no host:

```yaml
# antes
ports:
  - "127.0.0.1:8642:8642"

# agora — nada. A webui alcança pela rede docker (hermes-agent:8642).
```

Motivo concreto: com `API_SERVER_HOST=0.0.0.0` e `terminal.backend: local`, quem alcançar
a 8642 **com a chave** dispara trabalho como usuário do host. Publicar no loopback do host
não trazia benefício — a webui nunca usou aquele caminho — e acrescentava um alcance a
mais. Menos portas, menos caminhos.

Para depurar, use a rede docker em vez da porta:

```bash
docker exec hermes-webui curl -s http://hermes-agent:8642/health
```

---

## O que ainda pode ser feito

| Medida | Ganho | Custo |
|---|---|---|
| `terminal.backend: docker` no hermes | limita o estrago se alguém passar por tudo — hoje o agente roda comandos como usuário do host | pode quebrar funções do agente; exige teste |
| TLS mútuo (cliente com certificado) em vez de basic auth | elimina brute force por completo | um certificado por dispositivo seu |
| Cloudflare na frente | esconde o IP de origem, WAF, mitigação de DDoS | move o DNS de novo, e passa a depender de terceiro |
| Backup **fora da máquina** | é o que faltou em julho — hoje os dumps do Postgres e do Redis moram no mesmo disco | precisa de destino (S3, outra máquina) |

**O último é o mais importante.** As três primeiras camadas reduzem a chance de invasão;
só o backup externo reduz o *dano* quando algo passa. Foi exatamente a ausência dele que
transformou o incidente do basilio em perda total.

---

## Segredos

| O quê | Onde |
|---|---|
| Senha do basic auth da beth | `/etc/nginx/beth.htpasswd` — só o hash bcrypt, em lugar nenhum mais |

Nenhuma cópia em texto fica no servidor. A senha vive no BitWarden e no navegador.

Trocar a senha:

```bash
# interativo — a senha não passa por argv nem fica no histórico
htpasswd -B /etc/nginx/beth.htpasswd chico
```

Não precisa recarregar o nginx: o arquivo é lido a cada requisição.

> ⚠️ **Nunca com `htpasswd -b senha`.** A forma `-b` põe a senha em `argv`, onde ela fica
> visível no `ps` para qualquer usuário da máquina enquanto o comando roda, e no histórico
> do shell depois. Use `-B` interativo, ou `-i` lendo de stdin em script.

---

## Verificar o estado

```bash
# camadas ativas
fail2ban-client status
fail2ban-client status nginx-http-auth
fail2ban-client get nginx-http-auth logpath     # tem que listar ARQUIVOS

# nada de aplicação escutando em 0.0.0.0
ss -tlnp | grep LISTEN

# a senha responde
curl -s -o /dev/null -w '%{http_code}\n' https://beth.chicofigueiredo.com.br/          # 401
curl -s -o /dev/null -u chico:SENHA -w '%{http_code}\n' https://beth.chicofigueiredo.com.br/  # 302
```
