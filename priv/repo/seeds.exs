alias Pod.Repo
alias Pod.Interests.Interest
alias Pod.Moods.Mood

now = DateTime.utc_now() |> DateTime.truncate(:second)

interests =
  [
    %{name: "Technology", description: "Tech podcasts"},
    %{name: "Business", description: "Business & entrepreneurship"},
    %{name: "Sports", description: "Sports podcasts"},
    %{name: "Music", description: "Music & entertainment"},
    %{name: "News", description: "News & politics"},
    %{name: "Comedy", description: "Comedy & humor"},
    %{name: "Education", description: "Learning & education"},
    %{name: "Health", description: "Health & wellness"},
    %{name: "True Crime", description: "True crime stories"},
    %{name: "Religion", description: "Spirituality & faith"},
    %{name: "Science", description: "Science & discovery"},
    %{name: "History", description: "History & culture"},
    %{name: "Self-Help", description: "Personal development"},
    %{name: "Fiction", description: "Audiodramas & storytelling"},
    %{name: "Relationships", description: "Love & relationships"},
    %{name: "Parenting", description: "Parenting & family"},
    %{name: "Travel", description: "Travel & adventure"},
    %{name: "Food", description: "Cooking & food culture"},
    %{name: "Fashion", description: "Fashion & style"},
    %{name: "Gaming", description: "Video games & esports"},
    %{name: "Film", description: "Movies & TV discussion"},
    %{name: "Art", description: "Art & design"},
    %{name: "Nature", description: "Environment & wildlife"},
    %{name: "Career", description: "Career advice & development"},
    %{name: "Investing", description: "Finance & investing"}
  ]
  |> Enum.map(&Map.merge(&1, %{inserted_at: now, updated_at: now}))

moods =
  [
    %{name: "Focus", description: "Deep work & concentration"},
    %{name: "Chill", description: "Relaxing & unwinding"},
    %{name: "Workout", description: "Energy & motivation"},
    %{name: "Party", description: "High energy & fun"},
    %{name: "Sleep", description: "Calming & sleep aids"},
    %{name: "Learn", description: "Educational & growth"},
    %{name: "Commute", description: "Quick listens"},
    %{name: "Cooking", description: "Podcast while cooking"},
    %{name: "Laugh", description: "Comedy & humor"},
    %{name: "Inspire", description: "Motivation & mindfulness"},
    %{name: "Thriller", description: "Suspense & mystery"},
    %{name: "Storytelling", description: "Narratives & fiction"},
    %{name: "Drama", description: "Emotional & engaging"},
    %{name: "Trending", description: "What's hot now"},
    %{name: "Hidden Gems", description: "Underrated podcasts"}
  ]



Repo.insert_all(
  Interest,
  Enum.map(interests, fn interest ->
    %{
      name: interest.name,
      description: interest.description,
      inserted_at: now,
      updated_at: now
    }
  end),
  on_conflict: :nothing,
  conflict_target: :name
)

Repo.insert_all(
  Mood,
  Enum.map(moods, fn mood ->
    %{
      name: mood.name,
      description: mood.description,
      inserted_at: now,
      updated_at: now
    }
  end),
  on_conflict: :nothing,
  conflict_target: :name
)
