# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Inside the script, you can read and write to any of your
# repositories directly:
#
#     Pod.Repo.insert!(%Pod.SomeSchema{})
#
# We recommend using the bang functions (`insert!`, `update!`
# and so on) as they will fail if something goes wrong.
alias Pod.Repo
alias Pod.Interests.Interest

interests = [
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

Enum.each(interests, fn interest ->
  Repo.insert!(%Interest{
    name: interest.name,
    description: interest.description
  })
end)
