-- phpMyAdmin SQL Dump
-- version 5.2.1
-- https://www.phpmyadmin.net/
--
-- Host: 127.0.0.1
-- Tempo de geração: 14-Jul-2025 às 23:11
-- Versão do servidor: 10.4.32-MariaDB
-- versão do PHP: 8.2.12

SET SQL_MODE = "NO_AUTO_VALUE_ON_ZERO";
START TRANSACTION;
SET time_zone = "+00:00";


/*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;
/*!40101 SET @OLD_CHARACTER_SET_RESULTS=@@CHARACTER_SET_RESULTS */;
/*!40101 SET @OLD_COLLATION_CONNECTION=@@COLLATION_CONNECTION */;
/*!40101 SET NAMES utf8mb4 */;

--
-- Banco de dados: `sigepoli`
--

DELIMITER $$
--
-- Procedimentos
--
CREATE DEFINER=`root`@`localhost` PROCEDURE `AlocarProfessor` (IN `p_professor_id` INT, IN `p_disciplina_id` INT, IN `p_turma_id` INT, IN `p_horario_inicio` TIME, IN `p_horario_fim` TIME, IN `p_dia_semana` VARCHAR(3), IN `p_sala` VARCHAR(20), IN `p_vagas` INT, IN `p_coordenador_id` INT)   BEGIN
    DECLARE v_curso_id INT;
    DECLARE v_coordenador_curso_id INT;
    DECLARE v_conflito INT;
    
    -- Verificar se coordenador pertence ao curso
    SELECT curso_id INTO v_curso_id FROM Turma WHERE id = p_turma_id;
    SELECT coordenador_id INTO v_coordenador_curso_id FROM Curso WHERE id = v_curso_id;
    
    IF v_coordenador_curso_id != p_coordenador_id THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Apenas o coordenador do curso pode fazer alocações';
    END IF;
    
    -- Verificar conflito de horários
    SELECT COUNT(*) INTO v_conflito
    FROM ProfessorDisciplinaTurma
    WHERE professor_id = p_professor_id
    AND dia_semana = p_dia_semana
    AND (
        (p_horario_inicio BETWEEN horario_inicio AND horario_fim) OR
        (p_horario_fim BETWEEN horario_inicio AND horario_fim) OR
        (horario_inicio BETWEEN p_horario_inicio AND p_horario_fim)
    );
    
    IF v_conflito > 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Professor já tem aula em horário sobreposto';
    ELSE
        -- Criar alocação (já aprovada pelo coordenador)
        INSERT INTO ProfessorDisciplinaTurma (
            professor_id, disciplina_id, turma_id, 
            horario_inicio, horario_fim, dia_semana, 
            sala, vagas, vagas_disponiveis, aprovado_coordenador
        ) VALUES (
            p_professor_id, p_disciplina_id, p_turma_id,
            p_horario_inicio, p_horario_fim, p_dia_semana,
            p_sala, p_vagas, p_vagas, TRUE
        );
    END IF;
END$$

CREATE DEFINER=`root`@`localhost` PROCEDURE `MatricularAluno` (IN `p_aluno_id` INT, IN `p_professor_disciplina_turma_id` INT)   BEGIN
    DECLARE v_vagas_disponiveis INT;
    DECLARE v_status_pagamento BOOLEAN;
    DECLARE v_aluno_curso_id INT;
    DECLARE v_turma_curso_id INT;
    
    -- Verificar vagas
    SELECT vagas_disponiveis INTO v_vagas_disponiveis 
    FROM ProfessorDisciplinaTurma 
    WHERE id = p_professor_disciplina_turma_id;
    
    -- Verificar pagamento
    SELECT status_pagamento INTO v_status_pagamento 
    FROM Aluno a JOIN Matricula m ON a.id = m.aluno_id
    WHERE a.id = p_aluno_id AND m.status_pagamento = FALSE LIMIT 1;
    
    -- Verificar se aluno pertence ao curso da turma
    SELECT curso_id INTO v_aluno_curso_id FROM Aluno WHERE id = p_aluno_id;
    
    SELECT t.curso_id INTO v_turma_curso_id 
    FROM ProfessorDisciplinaTurma pdt
    JOIN Turma t ON pdt.turma_id = t.id
    WHERE pdt.id = p_professor_disciplina_turma_id;
    
    IF v_vagas_disponiveis <= 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Não há vagas disponíveis';
    ELSEIF v_status_pagamento IS NOT NULL AND v_status_pagamento = FALSE THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Aluno possui propinas pendentes';
    ELSEIF v_aluno_curso_id != v_turma_curso_id THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Aluno não pertence ao curso desta turma';
    ELSE
        -- Efetuar matrícula
        INSERT INTO Matricula (aluno_id, professor_disciplina_turma_id) 
        VALUES (p_aluno_id, p_professor_disciplina_turma_id);
        
        -- Atualizar vagas
        UPDATE ProfessorDisciplinaTurma 
        SET vagas_disponiveis = vagas_disponiveis - 1 
        WHERE id = p_professor_disciplina_turma_id;
    END IF;
END$$

CREATE DEFINER=`root`@`localhost` PROCEDURE `ProcessarPagamento` (IN `p_contrato_id` INT, IN `p_mes` INT, IN `p_ano` INT)   BEGIN
    DECLARE v_valor_base DECIMAL(12,2);
    DECLARE v_sla_percentual DECIMAL(5,2);
    DECLARE v_sla_minimo DECIMAL(5,2);
    DECLARE v_multa_percentual DECIMAL(5,2);
    DECLARE v_garantia_valida BOOLEAN;
    
    -- Verificar garantia (RN04)
    SELECT e.garantia_valida INTO v_garantia_valida
    FROM EmpresaTerceirizada e
    JOIN Contrato c ON e.id = c.empresa_id
    WHERE c.id = p_contrato_id;
    
    IF v_garantia_valida = FALSE THEN
        -- Bloquear pagamento
        INSERT INTO Pagamento (contrato_id, data_pagamento, valor_base, valor_multa, mes_referencia, ano_referencia, status)
        VALUES (p_contrato_id, CURDATE(), 0, 0, p_mes, p_ano, 'BLOQUEADO');
        
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Pagamento bloqueado: garantia inválida';
    ELSE
        -- Obter valores do contrato
        SELECT valor_mensal, sla_minimo, multa_sla 
        INTO v_valor_base, v_sla_minimo, v_multa_percentual
        FROM Contrato WHERE id = p_contrato_id;
        
        -- Obter SLA do mês
        SELECT percentual INTO v_sla_percentual
        FROM SLA 
        WHERE contrato_id = p_contrato_id AND mes = p_mes AND ano = p_ano;
        
        -- Calcular multa se SLA abaixo do mínimo (RN05)
        IF v_sla_percentual < v_sla_minimo THEN
            SET @valor_multa = v_valor_base * (v_multa_percentual / 100);
        ELSE
            SET @valor_multa = 0;
        END IF;
        
        -- Registrar pagamento
        INSERT INTO Pagamento (
            contrato_id, data_pagamento, valor_base, 
            valor_multa, mes_referencia, ano_referencia, status
        ) VALUES (
            p_contrato_id, CURDATE(), v_valor_base, 
            @valor_multa, p_mes, p_ano, 'PAGO'
        );
    END IF;
END$$

--
-- Funções
--
CREATE DEFINER=`root`@`localhost` FUNCTION `CalcularMediaAluno` (`p_aluno_id` INT, `p_disciplina_id` INT) RETURNS DECIMAL(4,2) DETERMINISTIC BEGIN
    DECLARE v_media DECIMAL(4,2);
    
    SELECT SUM(a.nota * a.peso) / SUM(a.peso) INTO v_media
    FROM Avaliacao a
    JOIN Matricula m ON a.matricula_id = m.id
    JOIN ProfessorDisciplinaTurma pdt ON m.professor_disciplina_turma_id = pdt.id
    WHERE m.aluno_id = p_aluno_id AND pdt.disciplina_id = p_disciplina_id;
    
    RETURN IFNULL(v_media, 0);
END$$

CREATE DEFINER=`root`@`localhost` FUNCTION `CalcularSLAMensal` (`p_empresa_id` INT, `p_mes` INT, `p_ano` INT) RETURNS DECIMAL(5,2) DETERMINISTIC BEGIN
    DECLARE v_sla_percentual DECIMAL(5,2);
    
    -- Simulação: na prática viria de sistema de monitoramento
    SELECT RAND() * 100 INTO v_sla_percentual;
    
    RETURN v_sla_percentual;
END$$

DELIMITER ;

-- --------------------------------------------------------

--
-- Estrutura da tabela `aluno`
--

CREATE TABLE `aluno` (
  `id` int(11) NOT NULL,
  `nome` varchar(100) NOT NULL,
  `email` varchar(100) NOT NULL,
  `data_nascimento` date DEFAULT NULL,
  `curso_id` int(11) NOT NULL,
  `ano_matricula` int(11) NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8 COLLATE=utf8_general_ci;

--
-- Extraindo dados da tabela `aluno`
--

INSERT INTO `aluno` (`id`, `nome`, `email`, `data_nascimento`, `curso_id`, `ano_matricula`) VALUES
(1, 'Maria Pereira', 'maria@isptec.co.ao', '2000-05-15', 1, 2024),
(2, 'João Costa', 'joao@isptec.co.ao', '1999-08-22', 1, 2024);

-- --------------------------------------------------------

--
-- Estrutura da tabela `auditoria`
--

CREATE TABLE `auditoria` (
  `id` int(11) NOT NULL,
  `tabela_afetada` varchar(50) NOT NULL,
  `operacao` enum('INSERT','UPDATE','DELETE') NOT NULL,
  `id_registro` int(11) NOT NULL,
  `dados_anteriores` text DEFAULT NULL,
  `dados_novos` text DEFAULT NULL,
  `usuario` varchar(100) DEFAULT NULL,
  `data_hora` datetime DEFAULT current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8 COLLATE=utf8_general_ci;

-- --------------------------------------------------------

--
-- Estrutura da tabela `avaliacao`
--

CREATE TABLE `avaliacao` (
  `id` int(11) NOT NULL,
  `matricula_id` int(11) NOT NULL,
  `tipo` enum('PROVA','TRABALHO','PARTICIPACAO') NOT NULL,
  `nota` decimal(4,2) NOT NULL CHECK (`nota` >= 0 and `nota` <= 20),
  `peso` decimal(3,2) NOT NULL CHECK (`peso` > 0 and `peso` <= 1),
  `data_avaliacao` date NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8 COLLATE=utf8_general_ci;

-- --------------------------------------------------------

--
-- Estrutura stand-in para vista `cargahorariaprofessor`
-- (Veja abaixo para a view atual)
--
CREATE TABLE `cargahorariaprofessor` (
`professor` varchar(100)
,`disciplina` varchar(100)
,`curso` varchar(100)
,`alunos_matriculados` bigint(21)
,`carga_horaria_total` decimal(32,0)
);

-- --------------------------------------------------------

--
-- Estrutura da tabela `colaborador`
--

CREATE TABLE `colaborador` (
  `id` int(11) NOT NULL,
  `nome` varchar(100) NOT NULL,
  `email` varchar(100) NOT NULL,
  `tipo` enum('ADMINISTRATIVO','PROFESSOR','COORDENADOR') NOT NULL,
  `departamento_id` int(11) DEFAULT NULL,
  `data_contratacao` date NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8 COLLATE=utf8_general_ci;

--
-- Extraindo dados da tabela `colaborador`
--

INSERT INTO `colaborador` (`id`, `nome`, `email`, `tipo`, `departamento_id`, `data_contratacao`) VALUES
(1, 'Ana Silva', 'ana@isptec.co.ao', 'ADMINISTRATIVO', 1, '2020-01-15'),
(2, 'Carlos Rocha', 'carlos@isptec.co.ao', 'PROFESSOR', 1, '2019-05-20'),
(3, 'Pedro Santos', 'pedro@isptec.co.ao', 'COORDENADOR', 1, '2018-03-10');

-- --------------------------------------------------------

--
-- Estrutura da tabela `contrato`
--

CREATE TABLE `contrato` (
  `id` int(11) NOT NULL,
  `empresa_id` int(11) NOT NULL,
  `data_inicio` date NOT NULL,
  `data_fim` date NOT NULL,
  `valor_mensal` decimal(12,2) NOT NULL CHECK (`valor_mensal` > 0),
  `sla_minimo` decimal(5,2) NOT NULL CHECK (`sla_minimo` >= 0 and `sla_minimo` <= 100),
  `multa_sla` decimal(5,2) NOT NULL CHECK (`multa_sla` >= 0 and `multa_sla` <= 100)
) ;

--
-- Extraindo dados da tabela `contrato`
--

INSERT INTO `contrato` (`id`, `empresa_id`, `data_inicio`, `data_fim`, `valor_mensal`, `sla_minimo`, `multa_sla`) VALUES
(3, 1, '2024-01-01', '2024-12-31', 10000.00, 90.00, 5.00);

-- --------------------------------------------------------

--
-- Estrutura da tabela `curso`
--

CREATE TABLE `curso` (
  `id` int(11) NOT NULL,
  `nome` varchar(100) NOT NULL,
  `duracao_anos` int(11) NOT NULL CHECK (`duracao_anos` > 0),
  `coordenador_id` int(11) DEFAULT NULL,
  `departamento_id` int(11) NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8 COLLATE=utf8_general_ci;

--
-- Extraindo dados da tabela `curso`
--

INSERT INTO `curso` (`id`, `nome`, `duracao_anos`, `coordenador_id`, `departamento_id`) VALUES
(1, 'Engenharia Informática', 5, 3, 1),
(2, 'Gestão de Empresas', 4, NULL, 2);

-- --------------------------------------------------------

--
-- Estrutura da tabela `departamento`
--

CREATE TABLE `departamento` (
  `id` int(11) NOT NULL,
  `nome` varchar(100) NOT NULL,
  `orcamento_anual` decimal(12,2) NOT NULL,
  `chefe_id` int(11) DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8 COLLATE=utf8_general_ci;

--
-- Extraindo dados da tabela `departamento`
--

INSERT INTO `departamento` (`id`, `nome`, `orcamento_anual`, `chefe_id`) VALUES
(1, 'Informática', 800000.00, NULL),
(2, 'Gestão', 500000.00, NULL),
(3, 'Recursos Humanos', 0.00, NULL);

-- --------------------------------------------------------

--
-- Estrutura da tabela `disciplina`
--

CREATE TABLE `disciplina` (
  `id` int(11) NOT NULL,
  `nome` varchar(100) NOT NULL,
  `carga_horaria` int(11) NOT NULL CHECK (`carga_horaria` > 0),
  `curso_id` int(11) NOT NULL,
  `semestre` int(11) NOT NULL CHECK (`semestre` > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8 COLLATE=utf8_general_ci;

--
-- Extraindo dados da tabela `disciplina`
--

INSERT INTO `disciplina` (`id`, `nome`, `carga_horaria`, `curso_id`, `semestre`) VALUES
(1, 'Base de Dados II', 60, 1, 4),
(2, 'Programação Avançada', 75, 1, 3),
(3, 'Contabilidade', 45, 2, 2);

-- --------------------------------------------------------

--
-- Estrutura da tabela `empresaterceirizada`
--

CREATE TABLE `empresaterceirizada` (
  `id` int(11) NOT NULL,
  `nome` varchar(100) NOT NULL,
  `nif` varchar(20) NOT NULL,
  `tipo_servico` enum('LIMPEZA','SEGURANCA','CAFETARIA') NOT NULL,
  `garantia_valida` tinyint(1) DEFAULT 0,
  `data_validade_garantia` date DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8 COLLATE=utf8_general_ci;

--
-- Extraindo dados da tabela `empresaterceirizada`
--

INSERT INTO `empresaterceirizada` (`id`, `nome`, `nif`, `tipo_servico`, `garantia_valida`, `data_validade_garantia`) VALUES
(1, 'Limpeza Total', '123456789', 'LIMPEZA', 1, NULL);

-- --------------------------------------------------------

--
-- Estrutura stand-in para vista `gradehorariacurso`
-- (Veja abaixo para a view atual)
--
CREATE TABLE `gradehorariacurso` (
`curso` varchar(100)
,`ano` int(11)
,`semestre` int(11)
,`disciplina` varchar(100)
,`professor` varchar(100)
,`horario` varchar(25)
,`sala` varchar(20)
,`vagas_disponiveis` int(11)
);

-- --------------------------------------------------------

--
-- Estrutura da tabela `matricula`
--

CREATE TABLE `matricula` (
  `id` int(11) NOT NULL,
  `aluno_id` int(11) NOT NULL,
  `professor_disciplina_turma_id` int(11) NOT NULL,
  `data_matricula` datetime DEFAULT current_timestamp(),
  `status_pagamento` tinyint(1) DEFAULT 0
) ENGINE=InnoDB DEFAULT CHARSET=utf8 COLLATE=utf8_general_ci;

--
-- Acionadores `matricula`
--
DELIMITER $$
CREATE TRIGGER `AtualizarVagasCancelamento` AFTER DELETE ON `matricula` FOR EACH ROW BEGIN
    UPDATE ProfessorDisciplinaTurma 
    SET vagas_disponiveis = vagas_disponiveis + 1 
    WHERE id = OLD.professor_disciplina_turma_id;
END
$$
DELIMITER ;
DELIMITER $$
CREATE TRIGGER `AuditoriaMatriculas` AFTER INSERT ON `matricula` FOR EACH ROW BEGIN
    INSERT INTO Auditoria (
        tabela_afetada, operacao, id_registro, dados_novos
    ) VALUES (
        'Matricula', 'INSERT', NEW.id,
        CONCAT('aluno_id:', NEW.aluno_id, 
               ', disciplina_turma_id:', NEW.professor_disciplina_turma_id)
    );
END
$$
DELIMITER ;

-- --------------------------------------------------------

--
-- Estrutura da tabela `pagamento`
--

CREATE TABLE `pagamento` (
  `id` int(11) NOT NULL,
  `contrato_id` int(11) NOT NULL,
  `data_pagamento` date NOT NULL,
  `valor_base` decimal(12,2) NOT NULL CHECK (`valor_base` > 0),
  `valor_multa` decimal(12,2) DEFAULT 0.00 CHECK (`valor_multa` >= 0),
  `valor_total` decimal(12,2) GENERATED ALWAYS AS (`valor_base` + `valor_multa`) STORED,
  `mes_referencia` int(11) NOT NULL CHECK (`mes_referencia` >= 1 and `mes_referencia` <= 12),
  `ano_referencia` int(11) NOT NULL CHECK (`ano_referencia` > 2000),
  `status` enum('PENDENTE','PAGO','BLOQUEADO') DEFAULT 'PENDENTE'
) ENGINE=InnoDB DEFAULT CHARSET=utf8 COLLATE=utf8_general_ci;

--
-- Acionadores `pagamento`
--
DELIMITER $$
CREATE TRIGGER `BloquearPagamentoSemGarantia` BEFORE INSERT ON `pagamento` FOR EACH ROW BEGIN
    DECLARE v_garantia_valida BOOLEAN;
    
    SELECT e.garantia_valida INTO v_garantia_valida
    FROM EmpresaTerceirizada e
    JOIN Contrato c ON e.id = c.empresa_id
    WHERE c.id = NEW.contrato_id;
    
    IF v_garantia_valida = FALSE AND NEW.status != 'BLOQUEADO' THEN
        SET NEW.status = 'BLOQUEADO';
        SET NEW.valor_base = 0;
        SET NEW.valor_multa = 0;
    END IF;
END
$$
DELIMITER ;

-- --------------------------------------------------------

--
-- Estrutura da tabela `professor`
--

CREATE TABLE `professor` (
  `colaborador_id` int(11) NOT NULL,
  `titulacao` varchar(50) NOT NULL,
  `area_especializacao` varchar(100) DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8 COLLATE=utf8_general_ci;

--
-- Extraindo dados da tabela `professor`
--

INSERT INTO `professor` (`colaborador_id`, `titulacao`, `area_especializacao`) VALUES
(2, 'Doutor', 'Banco de Dados'),
(3, 'Mestre', 'Engenharia de Software');

-- --------------------------------------------------------

--
-- Estrutura da tabela `professordisciplinaturma`
--

CREATE TABLE `professordisciplinaturma` (
  `id` int(11) NOT NULL,
  `professor_id` int(11) NOT NULL,
  `disciplina_id` int(11) NOT NULL,
  `turma_id` int(11) NOT NULL,
  `horario_inicio` time NOT NULL,
  `horario_fim` time NOT NULL,
  `dia_semana` enum('SEG','TER','QUA','QUI','SEX','SAB') NOT NULL,
  `sala` varchar(20) NOT NULL,
  `vagas` int(11) NOT NULL CHECK (`vagas` > 0),
  `vagas_disponiveis` int(11) NOT NULL CHECK (`vagas_disponiveis` >= 0),
  `aprovado_coordenador` tinyint(1) DEFAULT 0
) ;

--
-- Extraindo dados da tabela `professordisciplinaturma`
--

INSERT INTO `professordisciplinaturma` (`id`, `professor_id`, `disciplina_id`, `turma_id`, `horario_inicio`, `horario_fim`, `dia_semana`, `sala`, `vagas`, `vagas_disponiveis`, `aprovado_coordenador`) VALUES
(1, 2, 2, 1, '10:00:00', '12:00:00', 'QUA', 'LAB2', 25, 25, 1);

--
-- Acionadores `professordisciplinaturma`
--
DELIMITER $$
CREATE TRIGGER `VerificarConflitoHorarioInsert` BEFORE INSERT ON `professordisciplinaturma` FOR EACH ROW BEGIN
    DECLARE v_conflito INT;
    
    SELECT COUNT(*) INTO v_conflito
    FROM ProfessorDisciplinaTurma
    WHERE professor_id = NEW.professor_id
    AND dia_semana = NEW.dia_semana
    AND (
        (NEW.horario_inicio BETWEEN horario_inicio AND horario_fim) OR
        (NEW.horario_fim BETWEEN horario_inicio AND horario_fim) OR
        (horario_inicio BETWEEN NEW.horario_inicio AND NEW.horario_fim)
    );
    
    IF v_conflito > 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Conflito de horário para este professor';
    END IF;
END
$$
DELIMITER ;

-- --------------------------------------------------------

--
-- Estrutura stand-in para vista `resumocustosservicos`
-- (Veja abaixo para a view atual)
--
CREATE TABLE `resumocustosservicos` (
`empresa` varchar(100)
,`servico` enum('LIMPEZA','SEGURANCA','CAFETARIA')
,`mes` int(11)
,`ano` int(11)
,`valor_contratado` decimal(12,2)
,`multa_aplicada` decimal(12,2)
,`valor_total` decimal(12,2)
,`sla_atingido` decimal(5,2)
,`status` varchar(13)
);

-- --------------------------------------------------------

--
-- Estrutura da tabela `sla`
--

CREATE TABLE `sla` (
  `id` int(11) NOT NULL,
  `contrato_id` int(11) NOT NULL,
  `mes` int(11) NOT NULL CHECK (`mes` >= 1 and `mes` <= 12),
  `ano` int(11) NOT NULL CHECK (`ano` > 2000),
  `percentual` decimal(5,2) NOT NULL CHECK (`percentual` >= 0 and `percentual` <= 100)
) ENGINE=InnoDB DEFAULT CHARSET=utf8 COLLATE=utf8_general_ci;

-- --------------------------------------------------------

--
-- Estrutura da tabela `turma`
--

CREATE TABLE `turma` (
  `id` int(11) NOT NULL,
  `codigo` varchar(20) NOT NULL,
  `curso_id` int(11) NOT NULL,
  `ano` int(11) NOT NULL,
  `semestre` int(11) NOT NULL CHECK (`semestre` in (1,2))
) ENGINE=InnoDB DEFAULT CHARSET=utf8 COLLATE=utf8_general_ci;

--
-- Extraindo dados da tabela `turma`
--

INSERT INTO `turma` (`id`, `codigo`, `curso_id`, `ano`, `semestre`) VALUES
(1, 'EI-2024-1', 1, 2024, 1),
(2, 'GE-2024-1', 2, 2024, 1);

-- --------------------------------------------------------

--
-- Estrutura para vista `cargahorariaprofessor`
--
DROP TABLE IF EXISTS `cargahorariaprofessor`;

CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `cargahorariaprofessor`  AS SELECT `col`.`nome` AS `professor`, `d`.`nome` AS `disciplina`, `c`.`nome` AS `curso`, count(`m`.`id`) AS `alunos_matriculados`, sum(`d`.`carga_horaria`) AS `carga_horaria_total` FROM ((((((`professor` `p` join `colaborador` `col` on(`p`.`colaborador_id` = `col`.`id`)) join `professordisciplinaturma` `pdt` on(`p`.`colaborador_id` = `pdt`.`professor_id`)) join `disciplina` `d` on(`pdt`.`disciplina_id` = `d`.`id`)) join `turma` `t` on(`pdt`.`turma_id` = `t`.`id`)) join `curso` `c` on(`t`.`curso_id` = `c`.`id`)) left join `matricula` `m` on(`pdt`.`id` = `m`.`professor_disciplina_turma_id`)) GROUP BY `col`.`nome`, `d`.`nome`, `c`.`nome` ORDER BY `col`.`nome` ASC ;

-- --------------------------------------------------------

--
-- Estrutura para vista `gradehorariacurso`
--
DROP TABLE IF EXISTS `gradehorariacurso`;

CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `gradehorariacurso`  AS SELECT `c`.`nome` AS `curso`, `t`.`ano` AS `ano`, `t`.`semestre` AS `semestre`, `d`.`nome` AS `disciplina`, `col`.`nome` AS `professor`, concat(`pdt`.`dia_semana`,' ',time_format(`pdt`.`horario_inicio`,'%H:%i'),'-',time_format(`pdt`.`horario_fim`,'%H:%i')) AS `horario`, `pdt`.`sala` AS `sala`, `pdt`.`vagas_disponiveis` AS `vagas_disponiveis` FROM (((((`curso` `c` join `turma` `t` on(`c`.`id` = `t`.`curso_id`)) join `professordisciplinaturma` `pdt` on(`t`.`id` = `pdt`.`turma_id`)) join `disciplina` `d` on(`pdt`.`disciplina_id` = `d`.`id`)) join `professor` `p` on(`pdt`.`professor_id` = `p`.`colaborador_id`)) join `colaborador` `col` on(`p`.`colaborador_id` = `col`.`id`)) ORDER BY `c`.`nome` ASC, `t`.`ano` ASC, `t`.`semestre` ASC, `pdt`.`dia_semana` ASC, `pdt`.`horario_inicio` ASC ;

-- --------------------------------------------------------

--
-- Estrutura para vista `resumocustosservicos`
--
DROP TABLE IF EXISTS `resumocustosservicos`;

CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `resumocustosservicos`  AS SELECT `e`.`nome` AS `empresa`, `e`.`tipo_servico` AS `servico`, `p`.`mes_referencia` AS `mes`, `p`.`ano_referencia` AS `ano`, `p`.`valor_base` AS `valor_contratado`, `p`.`valor_multa` AS `multa_aplicada`, `p`.`valor_total` AS `valor_total`, `s`.`percentual` AS `sla_atingido`, CASE WHEN `s`.`percentual` < `c`.`sla_minimo` THEN 'COM MULTA' ELSE 'DENTRO DO SLA' END AS `status` FROM (((`pagamento` `p` join `contrato` `c` on(`p`.`contrato_id` = `c`.`id`)) join `empresaterceirizada` `e` on(`c`.`empresa_id` = `e`.`id`)) left join `sla` `s` on(`s`.`contrato_id` = `c`.`id` and `s`.`mes` = `p`.`mes_referencia` and `s`.`ano` = `p`.`ano_referencia`)) ORDER BY `p`.`ano_referencia` ASC, `p`.`mes_referencia` ASC, `e`.`tipo_servico` ASC ;

--
-- Índices para tabelas despejadas
--

--
-- Índices para tabela `aluno`
--
ALTER TABLE `aluno`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `email` (`email`),
  ADD KEY `curso_id` (`curso_id`);

--
-- Índices para tabela `auditoria`
--
ALTER TABLE `auditoria`
  ADD PRIMARY KEY (`id`);

--
-- Índices para tabela `avaliacao`
--
ALTER TABLE `avaliacao`
  ADD PRIMARY KEY (`id`),
  ADD KEY `matricula_id` (`matricula_id`);

--
-- Índices para tabela `colaborador`
--
ALTER TABLE `colaborador`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `email` (`email`),
  ADD KEY `departamento_id` (`departamento_id`);

--
-- Índices para tabela `contrato`
--
ALTER TABLE `contrato`
  ADD PRIMARY KEY (`id`),
  ADD KEY `empresa_id` (`empresa_id`);

--
-- Índices para tabela `curso`
--
ALTER TABLE `curso`
  ADD PRIMARY KEY (`id`),
  ADD KEY `coordenador_id` (`coordenador_id`),
  ADD KEY `departamento_id` (`departamento_id`);

--
-- Índices para tabela `departamento`
--
ALTER TABLE `departamento`
  ADD PRIMARY KEY (`id`),
  ADD KEY `chefe_id` (`chefe_id`);

--
-- Índices para tabela `disciplina`
--
ALTER TABLE `disciplina`
  ADD PRIMARY KEY (`id`),
  ADD KEY `curso_id` (`curso_id`);

--
-- Índices para tabela `empresaterceirizada`
--
ALTER TABLE `empresaterceirizada`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `nif` (`nif`);

--
-- Índices para tabela `matricula`
--
ALTER TABLE `matricula`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `aluno_id` (`aluno_id`,`professor_disciplina_turma_id`),
  ADD KEY `professor_disciplina_turma_id` (`professor_disciplina_turma_id`);

--
-- Índices para tabela `pagamento`
--
ALTER TABLE `pagamento`
  ADD PRIMARY KEY (`id`),
  ADD KEY `contrato_id` (`contrato_id`);

--
-- Índices para tabela `professor`
--
ALTER TABLE `professor`
  ADD PRIMARY KEY (`colaborador_id`);

--
-- Índices para tabela `professordisciplinaturma`
--
ALTER TABLE `professordisciplinaturma`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `disciplina_id` (`disciplina_id`,`turma_id`),
  ADD KEY `professor_id` (`professor_id`),
  ADD KEY `turma_id` (`turma_id`);

--
-- Índices para tabela `sla`
--
ALTER TABLE `sla`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `contrato_id` (`contrato_id`,`mes`,`ano`);

--
-- Índices para tabela `turma`
--
ALTER TABLE `turma`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `codigo` (`codigo`),
  ADD KEY `curso_id` (`curso_id`);

--
-- AUTO_INCREMENT de tabelas despejadas
--

--
-- AUTO_INCREMENT de tabela `aluno`
--
ALTER TABLE `aluno`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=3;

--
-- AUTO_INCREMENT de tabela `auditoria`
--
ALTER TABLE `auditoria`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT de tabela `avaliacao`
--
ALTER TABLE `avaliacao`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT de tabela `colaborador`
--
ALTER TABLE `colaborador`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=4;

--
-- AUTO_INCREMENT de tabela `contrato`
--
ALTER TABLE `contrato`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT de tabela `curso`
--
ALTER TABLE `curso`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=3;

--
-- AUTO_INCREMENT de tabela `departamento`
--
ALTER TABLE `departamento`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=4;

--
-- AUTO_INCREMENT de tabela `disciplina`
--
ALTER TABLE `disciplina`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=4;

--
-- AUTO_INCREMENT de tabela `empresaterceirizada`
--
ALTER TABLE `empresaterceirizada`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=2;

--
-- AUTO_INCREMENT de tabela `matricula`
--
ALTER TABLE `matricula`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=2;

--
-- AUTO_INCREMENT de tabela `pagamento`
--
ALTER TABLE `pagamento`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT de tabela `professordisciplinaturma`
--
ALTER TABLE `professordisciplinaturma`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT de tabela `sla`
--
ALTER TABLE `sla`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT de tabela `turma`
--
ALTER TABLE `turma`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=3;

--
-- Restrições para despejos de tabelas
--

--
-- Limitadores para a tabela `aluno`
--
ALTER TABLE `aluno`
  ADD CONSTRAINT `aluno_ibfk_1` FOREIGN KEY (`curso_id`) REFERENCES `curso` (`id`);

--
-- Limitadores para a tabela `avaliacao`
--
ALTER TABLE `avaliacao`
  ADD CONSTRAINT `avaliacao_ibfk_1` FOREIGN KEY (`matricula_id`) REFERENCES `matricula` (`id`);

--
-- Limitadores para a tabela `colaborador`
--
ALTER TABLE `colaborador`
  ADD CONSTRAINT `colaborador_ibfk_1` FOREIGN KEY (`departamento_id`) REFERENCES `departamento` (`id`);

--
-- Limitadores para a tabela `contrato`
--
ALTER TABLE `contrato`
  ADD CONSTRAINT `contrato_ibfk_1` FOREIGN KEY (`empresa_id`) REFERENCES `empresaterceirizada` (`id`);

--
-- Limitadores para a tabela `curso`
--
ALTER TABLE `curso`
  ADD CONSTRAINT `curso_ibfk_1` FOREIGN KEY (`coordenador_id`) REFERENCES `colaborador` (`id`),
  ADD CONSTRAINT `curso_ibfk_2` FOREIGN KEY (`departamento_id`) REFERENCES `departamento` (`id`);

--
-- Limitadores para a tabela `departamento`
--
ALTER TABLE `departamento`
  ADD CONSTRAINT `departamento_ibfk_1` FOREIGN KEY (`chefe_id`) REFERENCES `colaborador` (`id`);

--
-- Limitadores para a tabela `disciplina`
--
ALTER TABLE `disciplina`
  ADD CONSTRAINT `disciplina_ibfk_1` FOREIGN KEY (`curso_id`) REFERENCES `curso` (`id`);

--
-- Limitadores para a tabela `matricula`
--
ALTER TABLE `matricula`
  ADD CONSTRAINT `matricula_ibfk_1` FOREIGN KEY (`aluno_id`) REFERENCES `aluno` (`id`),
  ADD CONSTRAINT `matricula_ibfk_2` FOREIGN KEY (`professor_disciplina_turma_id`) REFERENCES `professordisciplinaturma` (`id`);

--
-- Limitadores para a tabela `pagamento`
--
ALTER TABLE `pagamento`
  ADD CONSTRAINT `pagamento_ibfk_1` FOREIGN KEY (`contrato_id`) REFERENCES `contrato` (`id`);

--
-- Limitadores para a tabela `professor`
--
ALTER TABLE `professor`
  ADD CONSTRAINT `professor_ibfk_1` FOREIGN KEY (`colaborador_id`) REFERENCES `colaborador` (`id`);

--
-- Limitadores para a tabela `professordisciplinaturma`
--
ALTER TABLE `professordisciplinaturma`
  ADD CONSTRAINT `professordisciplinaturma_ibfk_1` FOREIGN KEY (`professor_id`) REFERENCES `professor` (`colaborador_id`),
  ADD CONSTRAINT `professordisciplinaturma_ibfk_2` FOREIGN KEY (`disciplina_id`) REFERENCES `disciplina` (`id`),
  ADD CONSTRAINT `professordisciplinaturma_ibfk_3` FOREIGN KEY (`turma_id`) REFERENCES `turma` (`id`);

--
-- Limitadores para a tabela `sla`
--
ALTER TABLE `sla`
  ADD CONSTRAINT `sla_ibfk_1` FOREIGN KEY (`contrato_id`) REFERENCES `contrato` (`id`);

--
-- Limitadores para a tabela `turma`
--
ALTER TABLE `turma`
  ADD CONSTRAINT `turma_ibfk_1` FOREIGN KEY (`curso_id`) REFERENCES `curso` (`id`);
COMMIT;

/*!40101 SET CHARACTER_SET_CLIENT=@OLD_CHARACTER_SET_CLIENT */;
/*!40101 SET CHARACTER_SET_RESULTS=@OLD_CHARACTER_SET_RESULTS */;
/*!40101 SET COLLATION_CONNECTION=@OLD_COLLATION_CONNECTION */;
