module Database.PostgreSQL.Query.Entity
       ( Entity(..)
       , Ent
       ) where

import Data.Proxy
import Data.Text ( Text )
import Data.Typeable ( Typeable )
import Database.PostgreSQL.Query.Types

-- | Auxiliary typeclass for data types which can map to rows of some
-- table. This typeclass is used inside functions like 'pgSelectEntities' to
-- generate queries.
class Entity a where
    -- | Id type for this entity
    data EntityId a :: *
    -- | Table name of this entity
    tableName :: Proxy a -> FN
    -- | Field names without 'id' and 'created'. The order of field names must match
    -- with order of fields in 'ToRow' and 'FromRow' instances of this type.
    fieldNames :: Proxy a -> [FN]

deriving instance Typeable EntityId

-- | Entity with it's id
type Ent a = (EntityId a, a)
