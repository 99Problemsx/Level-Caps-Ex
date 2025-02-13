#-------------------------------------------------------------------------------
# Rare Candy edits for Level Caps
#-------------------------------------------------------------------------------
ItemHandlers::UseOnPokemonMaximum.add(:RARECANDY, proc { |item, pkmn|
  max_lv = LevelCapsEX.soft_cap? ? LevelCapsEX.level_cap : GameData::GrowthRate.max_level
  next max_lv - pkmn.level
})

ItemHandlers::UseOnPokemon.add(:RARECANDY, proc { |item, qty, pkmn, scene|
  if pkmn.shadowPokemon? || pkmn.level >= GameData::GrowthRate.max_level
    handle_max_level_or_shadow(scene, pkmn, item)
  elsif pkmn.crosses_level_cap?(true)
    scene.pbDisplay(_INTL("{1} refuses to eat the {2}.", pkmn.name, GameData::Item.get(item).name))
    next false
  else
    pbSEPlay("Pkmn level up")
    pbChangeLevel(pkmn, pkmn.level + qty, scene)
    scene.pbHardRefresh
    next true
  end
})

def handle_max_level_or_shadow(scene, pkmn, item)
  if pkmn.shadowPokemon?
    scene.pbDisplay(_INTL("It won't have any effect."))
    false
  else
    new_species = pkmn.check_evolution_on_level_up
    if !Settings::RARE_CANDY_USABLE_AT_MAX_LEVEL || !new_species
      scene.pbDisplay(_INTL("It won't have any effect."))
      false
    else
      evolve_pokemon(scene, pkmn, new_species)
      true
    end
  end
end

def evolve_pokemon(scene, pkmn, new_species)
  pbFadeOutInWithMusic do
    evo = PokemonEvolutionScene.new
    evo.pbStartScreen(pkmn, new_species)
    evo.pbEvolution
    evo.pbEndScreen
    scene.pbRefresh if scene.is_a?(PokemonPartyScreen)
  end
end

#-------------------------------------------------------------------------------
# EXP Candy Edits for Level Caps
#-------------------------------------------------------------------------------
[:EXPCANDYXS, :EXPCANDYS, :EXPCANDYM, :EXPCANDYL, :EXPCANDYXL].each do |candy|
  exp_candy_handler(candy)
end

def exp_candy_handler(candy)
  gain_amount = candy_gain_amount(candy)
  ItemHandlers::UseOnPokemonMaximum.add(candy, proc { |item, pkmn|
    max_exp = LevelCapsEX.soft_cap? ? pkmn.growth_rate.minimum_exp_for_level(LevelCapsEX.level_cap) : pkmn.growth_rate.maximum_exp
    next ((max_exp - pkmn.exp) / gain_amount.to_f).ceil
  })

  ItemHandlers::UseOnPokemon.add(candy, proc { |item, qty, pkmn, scene|
    next pbGainExpFromExpCandy(pkmn, gain_amount, qty, scene, item)
  })
end

def candy_gain_amount(candy)
  case candy
  when :EXPCANDYXS then 100
  when :EXPCANDYS then 800
  when :EXPCANDYM then 3_000
  when :EXPCANDYL then 10_000
  when :EXPCANDYXL then 30_000
  end
end

def pbGainExpFromExpCandy(pkmn, base_amt, qty, scene, item)
  if pkmn.level >= GameData::GrowthRate.max_level || pkmn.shadowPokemon?
    scene.pbDisplay(_INTL("It won't have any effect."))
    return false
  elsif pkmn.crosses_level_cap?(true)
    scene.pbDisplay(_INTL("{1} refuses to eat the {2}.", pkmn.name, GameData::Item.get(item).name))
    return false
  else
    pbSEPlay("Pkmn level up")
    scene.scene.pbSetHelpText("") if scene.is_a?(PokemonPartyScreen)
    (qty - 1).times { pkmn.changeHappiness("vitamin") } if qty > 1
    pkmn.apply_exp(base_amt * qty, true)
    scene.pbHardRefresh
    return true
  end
end

#-------------------------------------------------------------------------------
# Additions to Game Variables to log Level Cap changes and set defaults
#-------------------------------------------------------------------------------
class Game_Variables
  alias __level_caps__set_variable []= unless method_defined?(:__level_caps__set_variable)

  def []=(variable_id, value)
    old_value = self[variable_id]
    ret = __level_caps__set_variable(variable_id, value)
    log_level_cap_changes(variable_id, old_value, value) if value != old_value && LevelCapsEX::LOG_LEVEL_CAP_CHANGES
    display_level_cap_change_message(variable_id, value) if value != old_value && LevelCapsEX::DISPLAY_LEVEL_CAP_CHANGE_MESSAGE
    ret
  end

  private

  def log_level_cap_changes(variable_id, old_value, value)
    if variable_id == LevelCapsEX::LEVEL_CAP_VARIABLE
      echoln "Current Level Cap updated from Lv. #{old_value} to Lv. #{value}"
    elsif variable_id == LevelCapsEX::LEVEL_CAP_MODE_VARIABLE && self[LevelCapsEX::LEVEL_CAP_VARIABLE] != 0
      mode_names = ["None", "Hard Cap", "EXP Cap", "Obedience Cap"]
      old_name = mode_names[old_value] || "None"
      new_name = mode_names[value] || "None"
      echoln "Current Level Cap Mode updated from \"#{old_name}\" to \"#{new_name}\""
    end
  end

  class Game_Variables
    alias_method :original_set_variable, :[]=
  
    def []=(variable_id, value)
      old_value = self[variable_id]
      original_set_variable(variable_id, value)
      if variable_id == LevelCapsEX::LEVEL_CAP_VARIABLE && old_value != value && LevelCapsEX::DISPLAY_LEVEL_CAP_CHANGE_MESSAGE
        pbMessage(_INTL("The level cap has been raised to Level {1}.", value))
      end
    end
  end

module Game
  class << self
    alias __level_caps__start_new start_new unless method_defined?(:__level_caps__start_new)
  end

  def self.start_new(*args)
    __level_caps__start_new(*args)
    $game_variables[LevelCapsEX::LEVEL_CAP_MODE_VARIABLE] = LevelCapsEX::DEFAULT_LEVEL_CAP_MODE
  end
end

#-------------------------------------------------------------------------------
# Main Level Cap Module
#-------------------------------------------------------------------------------
module LevelCapsEX
  module_function

  def level_cap
    return Settings::MAXIMUM_LEVEL unless $game_variables && $game_variables[LEVEL_CAP_VARIABLE] > 0
    $game_variables[LEVEL_CAP_VARIABLE]
  end

  def level_cap_mode
    lv_cap_mode = $game_variables[LEVEL_CAP_MODE_VARIABLE]
    return lv_cap_mode if $game_variables && [1, 2, 3].include?(lv_cap_mode)
    0
  end

  def hard_cap?
    level_cap_mode == 1 && $game_variables[LEVEL_CAP_VARIABLE] > 0
  end

  def soft_cap?
    [2, 3].include?(level_cap_mode) && $game_variables[LEVEL_CAP_VARIABLE] > 0
  end

  def hard_level_cap
    max_lv = Settings::MAXIMUM_LEVEL
    return max_lv unless $game_variables
    lv_cap_mode = $game_variables[LEVEL_CAP_MODE_VARIABLE]
    lv_cap = $game_variables[LEVEL_CAP_VARIABLE]
    return max_lv if lv_cap > max_lv
    lv_cap > 0 && lv_cap_mode == 1 ? lv_cap : max_lv
  end

  def applicable_level_cap?(is_player)
    return true if is_player && $game_switches[APPLY_TO_PLAYER_SWITCH]
    return true if !is_player && $game_switches[APPLY_TO_OPPONENT_SWITCH]
    false
  end
end