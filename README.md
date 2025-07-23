# Projeto-de-BD-2-SIGEPOLI---David-Teca

# SIGEPOLI - Sistema de Gestão Politécnica Integrado

Este projeto representa a estrutura de base de dados do **SIGEPOLI**, um sistema acadêmico completo para gestão de instituições de ensino politécnico. A base de dados foi desenvolvida em **MySQL/MariaDB** e contempla a gestão de alunos, professores, disciplinas, matrículas, contratos com empresas terceirizadas, pagamentos e muito mais.

## 📦 Conteúdo

O ficheiro `sigepoli.sql` contém:

- Estrutura completa de tabelas (alunos, professores, disciplinas, contratos, etc)
- Procedimentos armazenados (e.g., `AlocarProfessor`, `MatricularAluno`, `ProcessarPagamento`)
- Funções auxiliares (e.g., `CalcularMediaAluno`, `CalcularSLAMensal`)
- Views para relatórios (e.g., `cargahorariaprofessor`, `resumocustosservicos`, `gradehorariacurso`)
- Triggers de integridade e auditoria (e.g., atualização automática de vagas, auditoria de matrículas)
- Restrições de integridade referencial e validações de dados

## 🧩 Funcionalidades em Destaque

- **Alocação de Professores** com verificação de conflitos de horário e aprovação do coordenador
- **Matrículas** automáticas com validação de vagas, curso e estado de pagamento
- **Gestão de Contratos** com empresas terceirizadas e aplicação de multas por não conformidade com SLA
- **Auditoria** de operações críticas e controle de integridade via triggers
- **Cálculo automático** de médias ponderadas e indicadores SLA

BASE sigepoli;
