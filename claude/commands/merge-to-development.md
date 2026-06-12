Mergeia a branch atual na branch `development`.

## Passos

1. Salve o nome da branch atual: `git branch --show-current`
2. Certifique-se que a branch atual está atualizada com o remote: `git fetch origin`
3. Faça checkout na branch `development` e atualize-a: `git checkout development && git pull origin development`
4. Tente mergear a branch original na `development`: `git merge <branch-original>`

## Tratamento de conflitos

### Conflitos simples (poucos arquivos, resolvíveis)
Resolva os conflitos diretamente:
- Analise cada arquivo conflitante com `git diff`
- Aplique as resoluções mantendo as mudanças da branch original quando fizer sentido
- Finalize com `git add . && git commit`
- Push: `git push origin development`

### Conflitos complexos (muitos arquivos ou difíceis de resolver)
Antes de desistir, verifique a data do último commit na `development` **antes do merge** (use o reflog ou o histórico salvo):

```
git log development --before-merge --format="%ci" -1
```

Ou verificar pelo reflog da development antes de iniciar o merge:
```
git log origin/development -1 --format="%ci"
```

**Se o último commit da `development` for do dia anterior ou mais antigo:**
1. Abort do merge: `git merge --abort`
2. Resetar a `development` com a `main`:
   ```
   git fetch origin
   git reset --hard origin/main
   git push --force-with-lease origin development
   ```
3. Mergear a branch original novamente na `development` recém-resetada
4. Resolver os eventuais conflitos (agora serão bem menores)
5. Push: `git push origin development`

**Se o último commit da `development` for do dia atual (hoje):**
1. Abort do merge: `git merge --abort`
2. Avise o usuário:
   > "A branch `development` tem commits de hoje e está com muitos conflitos. Pode haver trabalho em andamento de outras pessoas. Recomendo verificar com o time antes de sobrescrever. Opções:
   > - Aguardar e tentar mergear mais tarde
   > - Sobrescrever `development` com `main` mesmo assim (risco de perder commits de hoje)
   > - Resolver os conflitos manualmente"

## Ao final (quando bem-sucedido)
- Retorne para a branch original: `git checkout <branch-original>`
- Confirme: "Branch `<branch-original>` mergeada com sucesso na `development`."
