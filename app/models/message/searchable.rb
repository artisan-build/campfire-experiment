module Message::Searchable
  extend ActiveSupport::Concern

  included do
    after_create_commit  :create_in_index
    after_update_commit  :update_in_index
    after_destroy_commit :remove_from_index

    scope :search, ->(query) {
      joins("join message_search_index idx on messages.id = idx.message_id")
        .where("to_tsvector('english', idx.body) @@ plainto_tsquery('english', ?)", query)
        .ordered
    }
  end

  private
    def create_in_index
      execute_sql_with_binds "insert into message_search_index(message_id, body) values (?, ?)", id, plain_text_body
    end

    def update_in_index
      execute_sql_with_binds "update message_search_index set body = ? where message_id = ?", plain_text_body, id
    end

    def remove_from_index
      execute_sql_with_binds "delete from message_search_index where message_id = ?", id
    end

    def execute_sql_with_binds(*statement)
      self.class.connection.execute self.class.sanitize_sql(statement)
    end
end
