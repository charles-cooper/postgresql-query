module Database.PostgreSQL.Query.Functions
       ( -- * Raw query execution
         pgQuery
       , pgExecute
       , pgQueryEntities
         -- * Transactions
       , pgWithTransaction
       , pgWithSavepoint
       , pgWithTransactionMode
       , pgWithTransactionModeRetry
       , pgWithTransactionSerializable
         -- * Work with entities
       , pgInsertEntity
       , pgInsertManyEntities
       , pgInsertManyEntitiesId
       , pgSelectEntities
       , pgSelectJustEntities
       , pgSelectEntitiesBy
       , pgGetEntity
       , pgGetEntityBy
       , pgDeleteEntity
       , pgUpdateEntity
       , pgSelectCount
         -- * Auxiliary functions
       , pgRepsertRow
       ) where

import Prelude

import Control.Applicative
import Control.Monad
import Control.Monad.Base
import Control.Monad.Logger
import Control.Monad.Trans.Control
import Data.Int ( Int64 )
import Data.Maybe ( listToMaybe )
import Data.Monoid
import Data.Proxy ( Proxy(..) )
import Data.Typeable ( Typeable )
import Database.PostgreSQL.Query.Entity
    ( Entity(..), Ent )
import Database.PostgreSQL.Query.Internal
    ( insertEntity, selectEntity, entityFieldsId,
      entityFields, selectEntitiesBy, insertManyEntities,
      updateTable, insertInto )
import Database.PostgreSQL.Query.SqlBuilder
    ( ToSqlBuilder(..), runSqlBuilder )
import Database.PostgreSQL.Query.TH
    ( sqlExp )
import Database.PostgreSQL.Query.Types
    ( FN, HasPostgres(..), TransactionSafe,
      ToMarkedRow(..), MarkedRow(..), mrToBuilder )
import Database.PostgreSQL.Simple
    ( ToRow, FromRow, execute_, query_, )
import Database.PostgreSQL.Simple.FromField
    ( FromField )
import Database.PostgreSQL.Simple.Internal
    ( SqlError )
import Database.PostgreSQL.Simple.ToField
    ( ToField )
import Database.PostgreSQL.Simple.Transaction
import Database.PostgreSQL.Simple.Types
    ( Query(..), Only(..), (:.)(..) )

import qualified Data.List as L
import qualified Data.List.NonEmpty as NL
import qualified Data.Text.Encoding as T

-- | Execute all queries inside one transaction. Rollback transaction on exceptions
pgWithTransaction :: (HasPostgres m, MonadBaseControl IO m, TransactionSafe m)
                  => m a
                  -> m a
pgWithTransaction action = withPGConnection $ \con -> do
    control $ \runInIO -> do
        withTransaction con $ runInIO action

-- | Same as `pgWithTransaction` but executes queries inside savepoint
pgWithSavepoint :: (HasPostgres m, MonadBaseControl IO m, TransactionSafe m) => m a -> m a
pgWithSavepoint action = withPGConnection $ \con -> do
    control $ \runInIO -> do
        withSavepoint con $ runInIO action

-- | Wrapper for 'withTransactionMode': Execute an action inside a SQL
-- transaction with a given transaction mode.
pgWithTransactionMode :: (HasPostgres m, MonadBaseControl IO m, TransactionSafe m)
                       => TransactionMode
                       -> m a
                       -> m a
pgWithTransactionMode tmode ma = withPGConnection $ \con -> do
    control $ \runInIO -> do
        withTransactionMode tmode con $ runInIO ma

-- | Wrapper for 'withTransactionModeRetry': Like 'pgWithTransactionMode',
-- but also takes a custom callback to determine if a transaction
-- should be retried if an SqlError occurs. If the callback returns
-- True, then the transaction will be retried. If the callback returns
-- False, or an exception other than an SqlError occurs then the
-- transaction will be rolled back and the exception rethrown.
pgWithTransactionModeRetry :: (HasPostgres m, MonadBaseControl IO m, TransactionSafe m)
                           => TransactionMode
                           -> (SqlError -> Bool)
                           -> m a
                           -> m a
pgWithTransactionModeRetry tmode epred ma = withPGConnection $ \con -> do
    control $ \runInIO -> do
        withTransactionModeRetry tmode epred con $ runInIO ma

-- | Wrapper for 'withTransactionSerializable': Execute an action
-- inside of a 'Serializable' transaction. If a serialization failure
-- occurs, roll back the transaction and try again. Be warned that
-- this may execute the IO action multiple times.
--
-- A Serializable transaction creates the illusion that your program
-- has exclusive access to the database. This means that, even in a
-- concurrent setting, you can perform queries in sequence without
-- having to worry about what might happen between one statement and
-- the next.
pgWithTransactionSerializable :: (HasPostgres m, MonadBaseControl IO m, TransactionSafe m)
                              => m a
                              -> m a
pgWithTransactionSerializable ma = withPGConnection $ \con -> do
    control $ \runInIO -> do
        withTransactionSerializable con $ runInIO ma

{- | Execute query generated by 'SqlBuilder'. Typical use case:

@
let userName = "Vovka Erohin" :: Text
pgQuery [sqlExp| SELECT id, name FROM users WHERE name = #{userName}|]
@

Or

@
let userName = "Vovka Erohin" :: Text
pgQuery $ Qp "SELECT id, name FROM users WHERE name = ?" [userName]
@

Which is almost the same. In both cases proper value escaping is performed
so you stay protected from sql injections.

-}

pgQuery :: (HasPostgres m, MonadLogger m, ToSqlBuilder q, FromRow r)
        => q -> m [r]
pgQuery q = withPGConnection $ \c -> do
    b <- liftBase $ runSqlBuilder c $ toSqlBuilder q
    logDebugN $ T.decodeUtf8 $ fromQuery b
    liftBase $ query_ c b

-- | Execute arbitrary query and return count of affected rows
pgExecute :: (HasPostgres m, MonadLogger m, ToSqlBuilder q)
          => q -> m Int64
pgExecute q = withPGConnection $ \c -> do
    b <- liftBase $ runSqlBuilder c $ toSqlBuilder q
    logDebugN $ T.decodeUtf8 $ fromQuery b
    liftBase $ execute_ c b

-- | Executes arbitrary query and parses it as entities and their ids
pgQueryEntities :: ( ToSqlBuilder q, HasPostgres m, MonadLogger m, Entity a
                  , FromRow a, FromField (EntityId a))
                => q -> m [Ent a]
pgQueryEntities q =
    map toTuples <$> pgQuery q
  where
    toTuples ((Only eid) :. entity) = (eid, entity)


-- | Insert new entity and return it's id
pgInsertEntity :: forall a m. (HasPostgres m, MonadLogger m, Entity a,
                         ToRow a, FromField (EntityId a))
               => a
               -> m (EntityId a)
pgInsertEntity a = do
    pgQuery [sqlExp|^{insertEntity a} RETURNING id|] >>= \case
        ((Only ret):_) -> return ret
        _       -> fail "Query did not return any response"


{- | Select entities as pairs of (id, entity).

@
handler :: Handler [Ent a]
handler = do
    now <- liftIO getCurrentTime
    let back = addUTCTime (days  (-7)) now
    pgSelectEntities id
        [sqlExp|WHERE created BETWEEN \#{now} AND \#{back}
               ORDER BY created|]

handler2 :: Text -> Handler [Ent Foo]
handler2 fvalue = do
    pgSelectEntities ("t"<>)
        [sqlExp|AS t INNER JOIN table2 AS t2
                ON t.t2_id = t2.id
                WHERE t.field = \#{fvalue}
                ORDER BY t2.field2|]
   -- Here the query will be: SELECT ... FROM tbl AS t INNER JOIN ...
@

-}

pgSelectEntities :: forall m a q. ( Functor m, HasPostgres m, MonadLogger m, Entity a
                            , FromRow a, ToSqlBuilder q, FromField (EntityId a) )
                 => (FN -> FN)   -- ^ Entity fields name modifier,
                                -- e.g. ("tablename"<>). Each field of
                                -- entity will be processed by this
                                -- modifier before pasting to the query
                 -> q           -- ^ part of query just after __SELECT .. FROM table__.
                 -> m [Ent a]
pgSelectEntities fpref q = do
    let p = Proxy :: Proxy a
    pgQueryEntities [sqlExp|^{selectEntity (entityFieldsId fpref) p} ^{q}|]


-- | Same as 'pgSelectEntities' but do not select id
pgSelectJustEntities :: forall m a q. ( Functor m, HasPostgres m, MonadLogger m, Entity a
                                 , FromRow a, ToSqlBuilder q )
                     => (FN -> FN)
                     -> q
                     -> m [a]
pgSelectJustEntities fpref q = do
    let p = Proxy :: Proxy a
    pgQuery [sqlExp|^{selectEntity (entityFields id fpref) p} ^{q}|]

{- | Select entities by condition formed from 'MarkedRow'. Usefull function when you know

-}

pgSelectEntitiesBy :: forall a m b.( Functor m, HasPostgres m, MonadLogger m, Entity a, ToMarkedRow b
                     , FromRow a, FromField (EntityId a) )
                   => b
                   -> m [Ent a]
pgSelectEntitiesBy b =
    let p = Proxy :: Proxy a
    in pgQueryEntities $ selectEntitiesBy ("id":) p b


-- | Select entity by id
--
-- @
-- getUser :: EntityId User ->  Handler User
-- getUser uid = do
--     pgGetEntity uid
--         >>= maybe notFound return
-- @
pgGetEntity :: forall m a. (ToField (EntityId a), Entity a,
                      HasPostgres m, MonadLogger m, FromRow a, Functor m)
            => EntityId a
            -> m (Maybe a)
pgGetEntity eid = do
    listToMaybe <$> pgSelectJustEntities id [sqlExp|WHERE id = #{eid} LIMIT 1|]


{- | Get entity by some fields constraint

@
getUser :: UserName -> Handler User
getUser name = do
    pgGetEntityBy
        (MR [("name", mkValue name),
             ("active", mkValue True)])
        >>= maybe notFound return
@

The query here will be like

@
pgQuery [sqlExp|SELECT id, name, phone ... FROM users WHERE name = #{name} AND active = #{True}|]
@

-}

pgGetEntityBy :: forall m a b. ( Entity a, HasPostgres m, MonadLogger m, ToMarkedRow b
                         , FromField (EntityId a), FromRow a, Functor m )
              => b               -- ^ uniq constrained list of fields and values
              -> m (Maybe (Ent a))
pgGetEntityBy b =
    let p = Proxy :: Proxy a
    in fmap listToMaybe
       $ pgQueryEntities
       [sqlExp|^{selectEntitiesBy ("id":) p b} LIMIT 1|]


-- | Same as 'pgInsertEntity' but insert many entities at one
-- action. Returns list of id's of inserted entities
pgInsertManyEntitiesId :: forall a m. ( Entity a, HasPostgres m, MonadLogger m
                                , ToRow a, FromField (EntityId a))
                       => [a]
                       -> m [EntityId a]
pgInsertManyEntitiesId [] = return []
pgInsertManyEntitiesId ents' =
    let ents = NL.fromList ents'
        q = [sqlExp|^{insertManyEntities ents} RETURNING id|]
    in map fromOnly <$> pgQuery q

-- | Insert many entities without returning list of id like
-- 'pgInsertManyEntitiesId' does
pgInsertManyEntities :: forall a m. (Entity a, HasPostgres m, MonadLogger m, ToRow a)
                     => [a]
                     -> m Int64
pgInsertManyEntities [] = return 0
pgInsertManyEntities ents' =
    let ents = NL.fromList ents'
    in pgExecute $ insertManyEntities ents


{- | Delete entity.

@
rmUser :: EntityId User -> Handler ()
rmUser uid = do
    pgDeleteEntity uid
@

Return 'True' if row was actually deleted.
-}

pgDeleteEntity :: forall a m. (Entity a, HasPostgres m, MonadLogger m, ToField (EntityId a), Functor m)
               => EntityId a
               -> m Bool
pgDeleteEntity eid =
    let p = Proxy :: Proxy a
    in fmap (1 ==)
       $ pgExecute [sqlExp|DELETE FROM ^{tableName p}
                           WHERE id = #{eid}|]


{- | Update entity using 'ToMarkedRow' instanced value. Requires 'Proxy'
while 'EntityId' is not a data type.

@
fixUser :: Text -> EntityId User -> Handler ()
fixUser username uid = do
    pgGetEntity uid
        >>= maybe notFound run
  where
    run user =
        pgUpdateEntity uid
        $ MR [("active", mkValue True)
              ("name", mkValue username)]
@

Returns 'True' if record was actually updated and 'False' if there was
not row with such id (or was more than 1, in fact)
-}

pgUpdateEntity :: forall a b m. (ToMarkedRow b, Entity a, HasPostgres m, MonadLogger m,
                           ToField (EntityId a), Functor m, Typeable a, Typeable b)
               => EntityId a
               -> b
               -> m Bool
pgUpdateEntity eid b =
    let p = Proxy :: Proxy a
        mr = toMarkedRow b
    in if L.null $ unMR mr
       then return False
       else fmap (1 ==)
            $ pgExecute [sqlExp|UPDATE ^{tableName p}
                                SET ^{mrToBuilder ", " mr}
                                WHERE id = #{eid}|]

{- | Select count of entities with given query

@
activeUsers :: Handler Integer
activeUsers = do
    pgSelectCount (Proxy :: Proxy User)
        [sqlExp|WHERE active = #{True}|]
@

-}

pgSelectCount :: forall m a q. ( Entity a, HasPostgres m, MonadLogger m, ToSqlBuilder q )
              => Proxy a
              -> q
              -> m Integer
pgSelectCount p q = do
    [[c]] <- pgQuery [sqlExp|SELECT count(id) FROM ^{tableName p} ^{q}|]
    return c



{- | Perform repsert of the same row, first trying "update where" then
"insert" with concatenated fields. Which means that if you run

@
pgRepsertRow "emails" (MR [("user_id", mkValue uid)]) (MR [("email", mkValue email)])
@

Then firstly will be performed

@
UPDATE "emails" SET email = 'foo@bar.com' WHERE "user_id" = 1234
@

And if no one row is affected (which is returned by 'pgExecute'), then

@
INSERT INTO "emails" ("user_id", "email") VALUES (1234, 'foo@bar.com')
@

will be performed

-}

pgRepsertRow :: (HasPostgres m, MonadLogger m, ToMarkedRow wrow, ToMarkedRow urow)
             => FN              -- ^ Table name
             -> wrow            -- ^ where condition
             -> urow            -- ^ update row
             -> m ()
pgRepsertRow tname wrow urow = do
    let wmr = toMarkedRow wrow
    aff <- pgExecute $ updateTable tname urow
           [sqlExp|WHERE ^{mrToBuilder "AND" wmr}|]
    when (aff == 0) $ do
        let umr = toMarkedRow urow
            imr = wmr <> umr
        _ <- pgExecute $ insertInto tname imr
        return ()
