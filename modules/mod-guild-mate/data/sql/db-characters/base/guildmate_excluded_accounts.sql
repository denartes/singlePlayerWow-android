--
-- Guild Mate: Excluded Accounts Table
-- Accounts in this table will NOT have their characters logged in as Guild Mates.
-- Use this to exclude your human player account(s).
--

DROP TABLE IF EXISTS `guildmate_excluded_accounts`;

CREATE TABLE `guildmate_excluded_accounts` (
    `account_id` INT UNSIGNED NOT NULL PRIMARY KEY COMMENT 'Account ID to exclude from Guild Mate',
    `notes` VARCHAR(255) DEFAULT NULL COMMENT 'Optional notes (e.g., "Human main account")'
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='Accounts excluded from Guild Mate auto-login';

--
-- Usage:
-- 1. Find your account ID:
--    SELECT id, username FROM account WHERE username = 'YourUsername';
--
-- 2. Add it to the exclusion list:
--    INSERT INTO guildmate_excluded_accounts (account_id, notes) VALUES (1, 'My main account');
--
